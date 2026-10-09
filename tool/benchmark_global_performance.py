"""Compare grouping and protected cache ranges with an explicit Git baseline.

Run from the repository root, with Flutter on PATH. Generated Dart and samples
stay under ignored build/global-perf/. This measures synthetic Flutter-test CPU
work, not release UI frame times, decoder throughput or physical disk latency.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time


DRIVER = r'''
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/identity/media_identity.dart' as current;
import 'package:rillight/player/cache/session_byte_cache.dart' as cache;
import 'identity_baseline.dart' as old;
import 'cache_baseline.dart' as old_cache;

void sample(String task, bool candidate, int trial, int micros) {
  print('BENCH ${jsonEncode({'task': task, 'candidate': candidate,
    'trial': trial, 'ms': micros / 1000})}');
}

void main() {
  test('global CPU benchmark', () async {
    var checksum = 0;
    for (final profile in [(1000, 1), (3000, 1), (1200, 4)]) {
      final (count, copies) = profile;
      final sources = [for (var i = 0; i < count; i++) current.WorkSource(
        reference: current.SourceReference(account: current.SourceAccount(
          region: current.AccessRegion.ordinary,
          configuredServerId: 'server-${i % copies}',
          verifiedServerId: 'verified-${i % copies}', userId: 'user',
        ), itemId: 'item-$i'), type: 'Movie', title: 'Title $i', year: 2025,
        providerIds: {'tmdb': '${i ~/ copies + 1}'},
      )];
      final before = [for (final s in sources) old.WorkSource(
        reference: old.SourceReference(account: s.reference.account,
          itemId: s.reference.itemId), type: s.type, title: s.title,
        year: s.year, providerIds: s.providerIds,
      )];
      for (var trial = -2; trial < 5; trial++) {
        for (final candidate in trial.isEven ? [false, true] : [true, false]) {
          final watch = Stopwatch()..start();
          final groups = candidate
            ? (current.WorkIndex()..upsert(sources)).groups.length
            : (old.WorkIndex()..upsert(before)).groups.length;
          watch.stop();
          expect(groups, count ~/ copies);
          checksum += groups;
          if (trial >= 0) sample('group-$count-copies-$copies', candidate, trial, watch.elapsedMicroseconds);
        }
      }
    }
    for (final count in [1024, 4096]) {
      final currentCache = await cache.SessionByteCache.open(
        memoryLimitBytes: count * 16, diskLimitBytes: 0);
      final oldCache = await old_cache.SessionByteCache.open(
        memoryLimitBytes: count * 16, diskLimitBytes: 0);
      try {
        for (var i = 0; i < count; i++) {
          final bytes = Uint8List.fromList(List.filled(16, i % 256));
          await currentCache.put(resource: 'synthetic', generation: 1, offset: i * 16, bytes: bytes);
          await oldCache.put(resource: 'synthetic', generation: 1, offset: i * 16, bytes: bytes);
        }
        for (var trial = -2; trial < 5; trial++) {
          for (final candidate in trial.isEven ? [false, true] : [true, false]) {
            final dynamic selected = candidate ? currentCache : oldCache;
            final watch = Stopwatch()..start();
            final dynamic lease = await selected.protectRange(
              resource: 'synthetic', generation: 1, offset: 0, length: count * 16);
            expect(lease, isNotNull);
            for (var i = 0; i < 512; i++) {
              final block = (i * 7919) % count;
              final dynamic read = await lease.read(block * 16, maxLength: 1);
              expect(read.bytes.single, block % 256);
              checksum += read.bytes.single as int;
            }
            await lease.close();
            watch.stop();
            if (trial >= 0) sample('range-$count-blocks-512-reads', candidate, trial, watch.elapsedMicroseconds);
          }
        }
      } finally {
        await currentCache.close();
        await oldCache.close();
      }
    }
    print('CHECKSUM $checksum');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, help='Git commit to compare')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    baseline = subprocess.check_output(
        ['git', 'rev-parse', '--verify', args.baseline + '^{commit}'], cwd=root,
        text=True).strip()
    out = root / 'build' / 'global-perf' / ('benchmark-' + str(time.time_ns()))
    out.mkdir(parents=True)
    snapshots = {
        'identity_baseline.dart': 'lib/aggregation/identity/media_identity.dart',
        'cache_baseline.dart': 'lib/player/cache/session_byte_cache.dart',
    }
    hashes = {}
    for destination, source in snapshots.items():
        body = subprocess.check_output(
            ['git', 'show', baseline + ':' + source], cwd=root).decode('utf-8')
        # Resolve original relative imports against their repository directory.
        def absolute_import(match):
            path = match.group(2)
            if ':' in path:
                return match.group(0)
            target = (root / source).parent.joinpath(path).resolve()
            uri = 'package:rillight/' + target.relative_to(root / 'lib').as_posix()
            return match.group(1) + "'" + uri + "'"
        body = re.sub(r"((?:import|export)\s+)'([^']+)'", absolute_import, body)
        (out / destination).write_text(body, encoding='utf-8')
        hashes[source] = hashlib.sha256((root / source).read_bytes()).hexdigest()
    (out / 'benchmark_test.dart').write_text(DRIVER, encoding='utf-8')
    (out / 'metadata.json').write_text(json.dumps({
        'baseline': baseline, 'candidate_file_sha256': hashes,
    }, indent=2), encoding='utf-8')
    flutter = shutil.which('flutter')
    if flutter is None:
        raise SystemExit('Flutter must be on PATH')
    print(out, flush=True)
    with (out / 'run.log').open('w', encoding='utf-8') as log:
        result = subprocess.run(
            [flutter, 'test', '--no-pub', '--concurrency=1', '--reporter',
             'expanded', str(out / 'benchmark_test.dart')], cwd=root,
            stdout=log, stderr=subprocess.STDOUT)
    output = (out / 'run.log').read_text(encoding='utf-8')
    samples = [json.loads(value) for value in re.findall(r'BENCH (\{[^\n]+\})', output)]
    (out / 'samples.json').write_text(json.dumps(samples, indent=2), encoding='utf-8')
    print(output, end='')
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()

"""Candidate-bound Android phone validation gate.

Evidence lives under ignored build/. The synthetic three-device runner can
exercise controls and media; physical output, power and heat need a real phone.
The gate never converts absent device observations into a passing result.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PHYSICAL_CHECKS = (
    'installed_launch', 'displayed_changing_video', 'physical_audio',
    'lock_and_unlock', 'retry_after_outage', 'source_switch_and_rollback',
    'buffered_seek', 'visible_images_and_scroll', 'background_resume',
    'power_and_thermal',
)


def command(*args):
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=900)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def candidate_identity():
    head = command('git', 'rev-parse', 'HEAD')
    status = command('git', 'status', '--porcelain', '-z', '--untracked-files=all')
    if head.returncode or status.returncode:
        raise RuntimeError('Git candidate identity unavailable')
    digest = hashlib.sha256()
    entries = []
    for item in filter(None, status.stdout.split('\0')):
        path = item[3:]
        # This validator never writes or reports the file content or a secret.
        file = ROOT / path
        if file.is_file():
            value = sha256(file)
            digest.update(path.encode() + b'\0' + value.encode() + b'\0')
            entries.append({'path': path, 'sha256': value})
        else:
            digest.update(item.encode() + b'\0')
    return {'head': head.stdout.strip(), 'dirty': bool(entries),
            'working_tree_sha256': digest.hexdigest(), 'changed_files': entries}


def validate_physical(record, identity, evidence_root):
    errors = []
    if not isinstance(record, dict):
        return ['Physical phone evidence is missing']
    if record.get('candidate_head') != identity['head'] or \
            record.get('working_tree_sha256') != identity['working_tree_sha256']:
        errors.append('Physical evidence belongs to another source candidate')
    apk_path = record.get('apk_path')
    apk_digest = record.get('apk_sha256')
    if not isinstance(apk_path, str) or not isinstance(apk_digest, str):
        errors.append('Physical evidence needs candidate APK path and SHA-256')
    else:
        apk = evidence_root / apk_path
        if not apk.resolve().is_relative_to(evidence_root.resolve()) or \
                not apk.is_file() or sha256(apk) != apk_digest:
            errors.append('Physical evidence APK hash mismatch or missing')
    if record.get('environment') != 'physical' or not record.get('device_fingerprint'):
        errors.append('Physical Android device identity is missing')
    checks = record.get('checks')
    for name in PHYSICAL_CHECKS:
        check = checks.get(name) if isinstance(checks, dict) else None
        if not isinstance(check, dict) or check.get('passed') is not True:
            errors.append(f'{name}: physical observation missing or failed')
            continue
        path, digest = check.get('evidence_path'), check.get('sha256')
        if not isinstance(path, str) or not isinstance(digest, str):
            errors.append(f'{name}: evidence path/hash missing')
            continue
        file = (evidence_root / path).resolve()
        if not file.is_relative_to(evidence_root.resolve()) or \
                not file.is_file() or sha256(file) != digest:
            errors.append(f'{name}: evidence hash mismatch or missing')
    return errors


def verify_candidate(evidence_root, *, run_android=True):
    evidence_root.mkdir(parents=True, exist_ok=True)
    identity = candidate_identity()
    errors = []
    checks = {}
    sdk = os.environ.get('RILLIGHT_CORE_SDK_ROOT')
    checks['native_sdk'] = bool(sdk and all(
        (Path(sdk) / abi / 'lib').is_dir() and
        any((Path(sdk) / abi / 'lib').glob('*.so'))
        for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64')))
    if not checks['native_sdk']:
        errors.append('Three-ABI Android core SDK input unavailable')
    try:
        adb = command('adb', 'devices', '-l') if checks['native_sdk'] else None
    except OSError:
        adb = None
    serials = [] if adb is None or adb.returncode else [
        line.split()[0] for line in adb.stdout.splitlines()[1:]
        if len(line.split()) > 1 and line.split()[1] == 'device'
    ]
    checks['connected_devices'] = serials
    if not serials:
        errors.append('Connected Android device/AVD unavailable')
    android_root = evidence_root / 'android'
    if run_android and checks['native_sdk'] and serials:
        result = command(sys.executable, 'tool/android_release_checks.py',
                         '--all-targets', '--output', str(android_root))
        checks['android_runner_exit'] = result.returncode
        # stdout/stderr may contain media URLs; store only the exit status.
        if result.returncode:
            errors.append('Current candidate Android device runner failed')
    android_result = android_root / 'result.json'
    if not android_result.is_file():
        errors.append('Current candidate Android 360dp/412dp/TV result missing')
    else:
        try:
            observed = json.loads(android_result.read_text(encoding='utf-8'))
            if observed.get('passed') is not True:
                errors.append('Current candidate Android device checks failed')
            if observed.get('source', {}).get('head') != identity['head']:
                errors.append('Android result belongs to another revision')
            if observed.get('source', {}).get('dirty') != identity['dirty']:
                errors.append('Android result source state differs from candidate')
        except (ValueError, OSError):
            errors.append('Android result is unreadable')
    physical_path = evidence_root / 'physical-phone.json'
    try:
        physical = json.loads(physical_path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        physical = None
    errors.extend(validate_physical(physical, identity, evidence_root))
    baseline = evidence_root / 'baseline.jsonl'
    candidate = evidence_root / 'candidate.jsonl'
    if baseline.is_file() and candidate.is_file():
        compared = command(sys.executable, 'tool/player_performance_checks.py',
                           '--compare-baseline', '--target', 'android-phone',
                           '--baseline', str(baseline), '--candidate', str(candidate))
        checks['paired_performance_exit'] = compared.returncode
        if compared.returncode:
            errors.append('Paired Android phone performance samples did not pass')
    else:
        errors.append('Paired Android phone baseline/candidate samples missing')
    after = candidate_identity()
    if after['head'] != identity['head'] or \
            after['working_tree_sha256'] != identity['working_tree_sha256']:
        errors.append('Source candidate changed during validation')
    result = {'passed': not errors, 'candidate': identity, 'checks': checks,
              'errors': errors, 'environment': 'unverified' if errors else 'physical'}
    (evidence_root / 'result.json').write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-candidate', action='store_true', required=True)
    parser.add_argument('--evidence-root', type=Path,
                        default=ROOT / 'build/phone-player-validation')
    args = parser.parse_args(argv)
    result = verify_candidate(args.evidence_root.resolve())
    print(json.dumps({'passed': result['passed'], 'evidence': str(args.evidence_root),
                      'errors': result['errors']}, ensure_ascii=False))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())

"""Candidate-bound Android phone validation gate.

Evidence lives under ignored build/. The synthetic three-device runner can
exercise controls and media; physical output, power and heat need a real phone.
The gate never converts absent device observations into a passing result.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import subprocess
import struct
import sys
import time
import uuid
import wave
from urllib.request import urlopen

from PIL import Image

from player_performance_checks import _screen_evidence_valid

ROOT = Path(__file__).resolve().parents[1]
PHYSICAL_CHECKS = (
    'installed_launch', 'displayed_changing_video', 'physical_audio',
    'lock_and_unlock', 'retry_after_outage', 'source_switch_and_rollback',
    'buffered_seek', 'visible_images_and_scroll', 'background_resume',
    'power_and_thermal',
)
PACKAGE = 'com.rillight.rillight.validation'
SCREEN_EVENTS = {
    'installed_launch': ('launch', 'home'),
    'displayed_changing_video': ('frame_a', 'frame_b'),
    'lock_and_unlock': ('lock', 'ordinary_tap', 'unlock'),
    'retry_after_outage': ('offline', 'retry', 'recovering', 'frame'),
    'source_switch_and_rollback': ('source_a', 'switch_b', 'source_b', 'rollback_a'),
    'buffered_seek': ('cached', 'offline', 'seek', 'frame'),
    'visible_images_and_scroll': ('scroll', 'image_visible'),
    'background_resume': ('background', 'foreground_paused'),
}
_PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'
PERFORMANCE_CATEGORIES = ('page', 'animation', 'image', 'startup')
PERFORMANCE_SCREEN = ('image', 'startup')


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


def live_physical_devices(serials):
    devices = {}
    for serial in serials:
        prefix = ('adb', '-s', serial, 'shell')
        try:
            qemu = command(*prefix, 'getprop', 'ro.kernel.qemu')
            boot_qemu = command(*prefix, 'getprop', 'ro.boot.qemu')
            fingerprint = command(*prefix, 'getprop', 'ro.build.fingerprint')
            if (any(result.returncode for result in (qemu, boot_qemu, fingerprint)) or
                    '1' in (qemu.stdout.strip(), boot_qemu.stdout.strip()) or
                    serial.startswith('emulator-') or not fingerprint.stdout.strip() or
                    any(marker in fingerprint.stdout.lower() for marker in
                        ('emulator', 'sdk_gphone', 'generic'))):
                continue
            package = command(*prefix, 'pm', 'path', PACKAGE)
            paths = [line.removeprefix('package:').strip() for line in
                     package.stdout.splitlines() if line.startswith('package:')]
            installed = None
            if package.returncode == 0 and len(paths) == 1:
                digest = command(*prefix, 'sha256sum', paths[0])
                if digest.returncode == 0:
                    candidate = digest.stdout.split()[0].lower()
                    if len(candidate) == 64 and all(c in '0123456789abcdef' for c in candidate):
                        installed = candidate
            devices[serial] = {'serial': serial,
                               'fingerprint': fingerprint.stdout.strip(),
                               'installed_apk_sha256': installed}
        except (OSError, subprocess.TimeoutExpired):
            continue
    return devices


def audited_android_candidate(evidence_root, identity):
    manifest_path = evidence_root / 'candidate-build.json'
    try:
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None
    if not isinstance(manifest, dict):
        return None
    if (manifest.get('candidate_head') != identity['head'] or
            manifest.get('working_tree_sha256') != identity['working_tree_sha256']):
        return None
    result_path = _safe_file(evidence_root, manifest.get('result_path'),
                             manifest.get('result_sha256'))
    apk = _safe_file(evidence_root, manifest.get('apk_path'),
                     manifest.get('apk_sha256'))
    if result_path is None or apk is None:
        return None
    try:
        result = json.loads(result_path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None
    if not isinstance(result, dict):
        return None
    devices = result.get('devices')
    app = result.get('app_apk')
    if not isinstance(app, dict):
        return None
    native = app.get('native')
    if not isinstance(native, dict) or not isinstance(native.get('core_abis'), list) or \
            set(native['core_abis']) != \
            {'arm64-v8a', 'armeabi-v7a', 'x86_64'}:
        return None
    libraries = native.get('libraries')
    if (not isinstance(libraries, dict) or
            not all(isinstance(libraries.get(abi), dict) and
                    'librillight_core.so' in libraries[abi] and
                    'librillight_android_core.so' in libraries[abi]
                    for abi in native['core_abis']) or
            not isinstance(native.get('notice_hashes'), dict) or
            not native['notice_hashes']):
        return None
    source = result.get('source')
    if not isinstance(source, dict):
        return None
    if (result.get('passed') is not True or
            source.get('head') != identity['head'] or
            source.get('dirty') != identity['dirty'] or
            app.get('sha256') != manifest['apk_sha256'] or
            app.get('package') != PACKAGE or
            not isinstance(devices, list) or len(devices) < 3 or
            not all(isinstance(row, dict) and row.get('passed') is True
                    for row in devices) or
            not any(row.get('tv') is True for row in devices) or
            not all(any(row.get('tv') is False and
                        isinstance(row.get('width_dp'), (int, float)) and
                        abs(row['width_dp'] - width) <= 2
                        for row in devices) for width in (360, 412))):
        return None
    return {'path': manifest['apk_path'], 'sha256': manifest['apk_sha256'],
            'result_path': manifest['result_path']}


def _safe_file(root, name, digest):
    if (not isinstance(name, str) or Path(name).is_absolute() or
            not isinstance(digest, str) or len(digest) != 64):
        return None
    file = (root / name).resolve()
    if not file.is_relative_to(root.resolve()) or not file.is_file() or sha256(file) != digest:
        return None
    return file


def _capture_signature(key, payload):
    canonical = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode('utf-8')
    return hmac.new(key, canonical, hashlib.sha256).hexdigest()


def _capture_key(root, *, create=False):
    path = root / '.capture-key'
    if path.is_file():
        return bytes.fromhex(path.read_text(encoding='ascii').strip())
    if not create or (root / 'capture-ledger.json').exists():
        return None
    key = secrets.token_bytes(32)
    path.write_text(key.hex(), encoding='ascii')
    return key


def _validation_app_foreground(serial):
    try:
        activity = command('adb', '-s', serial, 'shell',
                           'dumpsys', 'activity', 'activities')
    except (OSError, subprocess.TimeoutExpired):
        return False
    if activity.returncode:
        return False
    return any(PACKAGE + '/' in line for line in activity.stdout.splitlines()
               if 'topResumedActivity' in line or 'mResumedActivity' in line)


def capture_live_screen(root, scenario, phase, identity, audited_apk, live_device):
    """Capture only adb output; caller cannot provide a PNG path or pixel bytes."""
    if scenario not in (*SCREEN_EVENTS, *PERFORMANCE_CATEGORIES) or phase not in ('before', 'after'):
        raise ValueError('Unknown screen capture scenario or phase')
    if not audited_apk or not live_device or \
            live_device.get('installed_apk_sha256') != audited_apk['sha256']:
        raise RuntimeError('Current audited APK is not installed on a live physical phone')
    serial = live_device['serial']
    if not _validation_app_foreground(serial):
        raise RuntimeError('Validation APK is not the foreground activity')
    captured = subprocess.run(['adb', '-s', serial, 'exec-out', 'screencap', '-p'],
                              cwd=ROOT, capture_output=True, timeout=30, check=True)
    if not _validation_app_foreground(serial):
        raise RuntimeError('Validation APK left the foreground during screen capture')
    if not captured.stdout.startswith(_PNG_SIGNATURE):
        raise RuntimeError('adb did not return a PNG screenshot')
    import io
    with Image.open(io.BytesIO(captured.stdout)) as image:
        image.verify()
    folder = root / 'captures'
    folder.mkdir(parents=True, exist_ok=True)
    filename = f'{scenario}-{phase}-{uuid.uuid4().hex}.png'
    path = folder / filename
    path.write_bytes(captured.stdout)
    payload = {'scenario': scenario, 'phase': phase,
               'device_serial': serial, 'device_fingerprint': live_device['fingerprint'],
               'installed_apk_sha256': audited_apk['sha256'],
               'candidate_head': identity['head'],
               'working_tree_sha256': identity['working_tree_sha256'],
               'path': path.relative_to(root).as_posix(),
               'sha256': sha256(path), 'captured_unix_ns': time.time_ns()}
    key = _capture_key(root, create=True)
    if key is None:
        raise RuntimeError('Capture ledger exists without its local signing key')
    ledger_path = root / 'capture-ledger.json'
    ledger = json.loads(ledger_path.read_text(encoding='utf-8')) if ledger_path.is_file() else []
    ledger.append({'payload': payload, 'signature': _capture_signature(key, payload)})
    ledger_path.write_text(json.dumps(ledger, indent=2), encoding='utf-8')
    return payload


def capture_live_performance(root, category, phase, sample_phase, identity,
                             artifact, live_device):
    """Read the installed probe and screen from the selected live adb phone."""
    if category not in PERFORMANCE_CATEGORIES or sample_phase not in ('baseline', 'candidate'):
        raise ValueError('Unsupported performance category or sample phase')
    if phase != 'after' and not (category in PERFORMANCE_SCREEN and phase == 'before'):
        raise ValueError('Only image/startup have a before capture')
    screenshot = capture_live_screen(root, category, phase, identity, artifact, live_device)
    if phase == 'before':
        return screenshot
    serial = live_device['serial']
    forwarded = command('adb', '-s', serial, 'forward', 'tcp:8798', 'tcp:8798')
    if forwarded.returncode:
        raise RuntimeError('Cannot forward the running app performance probe')
    start_ns = time.monotonic_ns()
    with urlopen('http://127.0.0.1:8798/state', timeout=10) as response:
        state = json.loads(response.read())
    end_ns = time.monotonic_ns()
    if not _validation_app_foreground(serial) or not isinstance(state, dict) or \
            state.get('platform') != 'android' or \
            state.get('buildMode') not in ('profile', 'release') or \
            not isinstance(state.get('elapsedMs'), (int, float)) or \
            state['elapsedMs'] < 0:
        raise RuntimeError('Live app probe state is unavailable or unsuitable')
    trace = {'probe': state, 'screenshot': screenshot, 'probeStartNs': start_ns,
             'probeEndNs': end_ns}
    folder = root / 'captures'
    path = folder / f'performance-probe-{uuid.uuid4().hex}.json'
    path.write_text(json.dumps(trace, ensure_ascii=False), encoding='utf-8')
    payload = {'id': uuid.uuid4().hex, 'phase': sample_phase, 'category': category,
               'path': path.relative_to(root).as_posix(), 'sha256': sha256(path),
               'device_serial': serial, 'device_fingerprint': live_device['fingerprint'],
               'installed_apk_sha256': artifact['sha256'],
               'candidate_head': identity['head'],
               'working_tree_sha256': identity['working_tree_sha256']}
    key = _capture_key(root, create=True)
    if key is None:
        raise RuntimeError('Capture ledger exists without its local signing key')
    ledger_path = root / 'performance-ledger.json'
    ledger = json.loads(ledger_path.read_text(encoding='utf-8')) if ledger_path.is_file() else []
    ledger.append({'payload': payload, 'signature': _capture_signature(key, payload)})
    ledger_path.write_text(json.dumps(ledger, indent=2), encoding='utf-8')
    return payload


def _screen_capture_bound(root, scenario, data, identity, audited_apk, live_device):
    after_path_key = ('displayedImageEvidencePath' if scenario == 'image'
                      else 'displayedFrameEvidencePath')
    after_hash_key = ('displayedImageEvidenceSha256' if scenario == 'image'
                      else 'displayedFrameEvidenceSha256')
    try:
        key = _capture_key(root)
        ledger = json.loads((root / 'capture-ledger.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return False
    if key is None or not isinstance(ledger, list):
        return False
    matched = {}
    for row in ledger:
        if not isinstance(row, dict) or not isinstance(row.get('payload'), dict):
            continue
        payload = row['payload']
        if not hmac.compare_digest(str(row.get('signature', '')),
                                   _capture_signature(key, payload)):
            continue
        if (payload.get('scenario') != scenario or
                payload.get('device_serial') != live_device['serial'] or
                payload.get('device_fingerprint') != live_device['fingerprint'] or
                payload.get('installed_apk_sha256') != audited_apk['sha256'] or
                payload.get('candidate_head') != identity['head'] or
                payload.get('working_tree_sha256') != identity['working_tree_sha256'] or
                _safe_file(root, payload.get('path'), payload.get('sha256')) is None):
            continue
        phase = payload.get('phase')
        if (phase == 'before' and
                data.get('screenBeforePath') == payload['path'] and
                data.get('screenBeforeSha256') == payload['sha256']) or \
                (phase == 'after' and
                 data.get(after_path_key) == payload['path'] and
                 data.get(after_hash_key) == payload['sha256']):
            matched[phase] = payload
    before, after = matched.get('before'), matched.get('after')
    return bool(before and after and
                before['captured_unix_ns'] < after['captured_unix_ns'] and
                data.get('screenBeforePath') == before['path'] and
                data.get('screenBeforeSha256') == before['sha256'] and
                data.get(after_path_key) == after['path'] and
                data.get(after_hash_key) == after['sha256'])


def _wav_rms(file):
    try:
        with wave.open(str(file), 'rb') as stream:
            if stream.getsampwidth() != 2 or stream.getframerate() < 8000 or \
                    stream.getnframes() / stream.getframerate() < 5:
                return None
            samples = stream.readframes(stream.getnframes())
            count = len(samples) // 2
            return (sum(value * value for (value,) in struct.iter_unpack('<h', samples)) /
                    count) ** .5 / 32768 if count else None
    except (OSError, wave.Error, struct.error):
        return None


def _valid_utc_timestamp(value):
    if not isinstance(value, str):
        return False
    try:
        observed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        return False
    return observed.tzinfo is not None and observed.utcoffset().total_seconds() == 0 and \
        observed <= datetime.now(timezone.utc)


def _valid_observation(name, data, root):
    if name in SCREEN_EVENTS:
        if data.get('events') != list(SCREEN_EVENTS[name]) or \
                not _screen_evidence_valid(data, root / 'observations.jsonl',
                                           prefix='displayedFrame'):
            return False
        if name == 'installed_launch':
            return data.get('package') == PACKAGE and _positive(data.get('launchMs'))
        if name == 'lock_and_unlock':
            before, locked = data.get('anchorBefore'), data.get('anchorLocked')
            return (data.get('ordinaryTapStayedLocked') is True and
                    isinstance(before, list) and isinstance(locked, list) and
                    len(before) == len(locked) == 4 and
                    all(isinstance(v, (int, float)) for v in before + locked) and
                    max(abs(a-b) for a, b in zip(before, locked)) <= 2)
        if name == 'retry_after_outage':
            first, last = data.get('recoveringMs'), data.get('displayedMs')
            return _positive(first) and _positive(last) and first < last <= 45000
        if name == 'source_switch_and_rollback':
            first, second = data.get('sourceBefore'), data.get('sourceAfter')
            return (isinstance(first, str) and isinstance(second, str) and
                    first and second and first != second and
                    data.get('rollbackSource') == first)
        if name == 'buffered_seek':
            target, ranges = data.get('seekMs'), data.get('cachedRangesMs')
            return (isinstance(target, (int, float)) and isinstance(ranges, list) and
                    data.get('offline') is True and
                    any(isinstance(r, list) and len(r) == 2 and
                        all(isinstance(v, (int, float)) for v in r) and
                        r[0] <= target <= r[1] for r in ranges))
        if name == 'visible_images_and_scroll':
            return _positive(data.get('firstDisplayedImageMs'))
        if name == 'background_resume':
            return data.get('resumedPaused') is True and data.get('audioFocusReleased') is True
        return True
    if name == 'physical_audio':
        ambient = _safe_file(root, data.get('ambientWavPath'), data.get('ambientWavSha256'))
        playback = _safe_file(root, data.get('playbackWavPath'), data.get('playbackWavSha256'))
        attestation_file = _safe_file(root, data.get('manualAttestationPath'),
                                      data.get('manualAttestationSha256'))
        if ambient is None or playback is None or attestation_file is None or \
                not data.get('microphoneDevice'):
            return False
        quiet = _wav_rms(ambient)
        audible = _wav_rms(playback)
        try:
            attestation = json.loads(attestation_file.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            return False
        # PCM amplitude is corroboration only. A person must separately attest
        # that the candidate was audible through the physical device speaker.
        return (quiet is not None and audible is not None and
                audible > max(.01, quiet * 2) and
                isinstance(attestation, dict) and
                attestation.get('schema') == 1 and
                attestation.get('kind') == 'physical-speaker-listening' and
                attestation.get('physicalSpeakerAudible') is True and
                attestation.get('speakerRoute') == 'built-in-speaker' and
                isinstance(attestation.get('attestedBy'), str) and
                len(attestation['attestedBy'].strip()) >= 3 and
                _valid_utc_timestamp(attestation.get('observedAtUtc')) and
                attestation.get('device_serial') == data.get('device_serial') and
                attestation.get('apk_sha256') == data.get('apk_sha256') and
                attestation.get('candidate_head') == data.get('candidate_head'))
    if name == 'power_and_thermal':
        samples = data.get('samples')
        if (data.get('environment') != 'physical' or
                data.get('method') not in ('power-rail', 'fuel-gauge') or
                not isinstance(samples, list) or len(samples) < 20):
            return False
        for sample in samples:
            if not isinstance(sample, dict) or any(not isinstance(sample.get(key), (int, float))
                for key in ('elapsedMs', 'energyMWh', 'tempC', 'brightnessPercent', 'volumePercent')):
                return False
        return (samples[-1]['elapsedMs'] - samples[0]['elapsedMs'] >= 300000 and
                samples[-1]['energyMWh'] > samples[0]['energyMWh'] and
                len({sample['brightnessPercent'] for sample in samples}) == 1 and
                len({sample['volumePercent'] for sample in samples}) == 1 and
                all(a['elapsedMs'] < b['elapsedMs'] for a, b in zip(samples, samples[1:])))
    return False


def _positive(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0


def validate_physical(record, identity, evidence_root, *, audited_apk=None,
                      live_device=None):
    errors = []
    if not isinstance(record, dict):
        return ['Physical phone evidence is missing']
    if not audited_apk:
        return ['Audited current-candidate APK unavailable']
    if not live_device:
        return ['Connected physical Android phone observation unavailable']
    if record.get('candidate_head') != identity['head'] or \
            record.get('working_tree_sha256') != identity['working_tree_sha256']:
        errors.append('Physical evidence belongs to another source candidate')
    apk_path = record.get('apk_path')
    apk_digest = record.get('apk_sha256')
    if apk_path != audited_apk['path'] or apk_digest != audited_apk['sha256'] or \
            _safe_file(evidence_root, apk_path, apk_digest) is None:
        errors.append('Physical evidence APK differs from audited runner build')
    if record.get('environment') != 'physical' or \
            record.get('device_serial') != live_device['serial'] or \
            record.get('device_fingerprint') != live_device['fingerprint'] or \
            live_device.get('installed_apk_sha256') != audited_apk['sha256']:
        errors.append('Physical device or installed APK is not live and matched')
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
        file = _safe_file(evidence_root, path, digest)
        if file is None:
            errors.append(f'{name}: evidence hash mismatch or missing')
            continue
        try:
            raw = file.read_text(encoding='utf-8')
            data = json.loads(raw)
        except (OSError, UnicodeError, ValueError):
            errors.append(f'{name}: raw observation is unreadable')
            continue
        if (not isinstance(data, dict) or '://' in raw or
                data.get('schema') != 2 or data.get('scenario') != name or
                data.get('device_serial') != live_device['serial'] or
                data.get('apk_sha256') != audited_apk['sha256'] or
                data.get('candidate_head') != identity['head'] or
                (name in SCREEN_EVENTS and not _screen_capture_bound(
                    evidence_root, name, data, identity, audited_apk, live_device)) or
                not _valid_observation(name, data, evidence_root)):
            errors.append(f'{name}: measured observation is incomplete or invalid')
    return errors


def _signed_performance_records(root):
    try:
        key = _capture_key(root)
        rows = json.loads((root / 'performance-ledger.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}
    if key is None or not isinstance(rows, list):
        return {}
    records = {}
    for record in rows:
        if not isinstance(record, dict) or not isinstance(record.get('payload'), dict):
            continue
        payload = record['payload']
        if (not hmac.compare_digest(str(record.get('signature', '')),
                                    _capture_signature(key, payload)) or
                not isinstance(payload.get('id'), str) or
                _safe_file(root, payload.get('path'), payload.get('sha256')) is None):
            continue
        records[payload['id']] = payload
    return records


def _performance_row_bound(row, payload, root):
    trace_file = _safe_file(root, payload.get('path'), payload.get('sha256'))
    if trace_file is None:
        return False
    try:
        trace = json.loads(trace_file.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return False
    if not isinstance(trace, dict) or not isinstance(trace.get('probe'), dict):
        return False
    probe = trace['probe']
    if (payload.get('category') != row.get('category') or
            payload.get('phase') != row.get('phase') or
            payload.get('device_fingerprint') != row.get('device') or
            payload.get('installed_apk_sha256') != row.get('artifactSha256') or
            probe.get('buildMode') != row.get('buildMode') or
            probe.get('label') != row.get('label') or
            probe.get('cache') != row.get('cache') or
            probe.get('device') != row.get('device') or
            probe.get('complete') is not row.get('complete') or
            probe.get('frameBudgetMs') != row.get('frameBudgetMs') or
            not isinstance(trace.get('probeStartNs'), int) or
            not isinstance(trace.get('probeEndNs'), int) or
            trace['probeEndNs'] < trace['probeStartNs']):
        return False
    category = row['category']
    if category not in PERFORMANCE_CATEGORIES:
        # Network stalls and hardware rails/thermals need their own live
        # collectors. Caller-authored JSON is analysis input, not gate evidence.
        return False
    if category == 'page':
        return row.get('firstOperableMs') == probe.get('firstOperableMs') and \
            isinstance(probe.get('firstOperableMs'), (int, float))
    if category == 'animation':
        return (row.get('uiFrameMs') == probe.get('uiFrameMs') and
                row.get('rasterFrameMs') == probe.get('rasterFrameMs') and
                row.get('elapsedMs') == probe.get('elapsedMs') and
                row.get('frameTimingsComplete') == probe.get('frameTimingsComplete'))
    screenshot = trace.get('screenshot')
    if (not isinstance(screenshot, dict) or screenshot.get('scenario') != category or
            screenshot.get('phase') != 'after' or
            screenshot.get('path') != row.get(
                'displayedImageEvidencePath' if category == 'image'
                else 'displayedFrameEvidencePath') or
            screenshot.get('sha256') != row.get(
                'displayedImageEvidenceSha256' if category == 'image'
                else 'displayedFrameEvidenceSha256')):
        return False
    identity = {'head': payload.get('candidate_head'),
                'working_tree_sha256': payload.get('working_tree_sha256')}
    artifact = {'sha256': payload.get('installed_apk_sha256')}
    live = {'serial': payload.get('device_serial'),
            'fingerprint': payload.get('device_fingerprint')}
    if not _screen_capture_bound(root, category, row, identity, artifact, live):
        return False
    metric = 'firstDisplayedImageMs' if category == 'image' else 'firstDisplayedFrameMs'
    return (row.get(metric) == probe.get('elapsedMs') and
            isinstance(row.get(metric), (int, float)) and
            row.get('elapsedMs') == probe.get('elapsedMs') and
            (category != 'image' or row.get('renderedImageObserved') ==
             probe.get('renderedImageObserved') is True))


def samples_match_live_probes(path, phase, audited_apk, device_fingerprint,
                              evidence_root, identity=None):
    if not device_fingerprint or (phase == 'candidate' and not audited_apk):
        return False
    records = _signed_performance_records(evidence_root)
    expected = ((evidence_root / audited_apk['path']).resolve()
                if phase == 'candidate' else None)
    seen = set()
    rows = 0
    try:
        for line in path.read_text(encoding='utf-8').splitlines():
            if not line.strip():
                continue
            sample = json.loads(line)
            if not isinstance(sample, dict):
                return False
            capture_id = sample.get('probeTraceId')
            payload = records.get(capture_id)
            if (capture_id in seen or payload is None or
                    sample.get('phase') != phase or
                    sample.get('target') != 'android-phone' or
                    sample.get('device') != device_fingerprint or
                    (expected is not None and
                     (sample.get('artifactSha256') != audited_apk['sha256'] or
                      (path.parent / sample.get('artifactPath', '')).resolve() != expected)) or
                    (identity is not None and phase == 'candidate' and
                     (payload.get('candidate_head') != identity['head'] or
                      payload.get('working_tree_sha256') != identity['working_tree_sha256'])) or
                    not _performance_row_bound(sample, payload, evidence_root)):
                return False
            seen.add(capture_id)
            rows += 1
    except (OSError, ValueError, TypeError, KeyError):
        return False
    return rows > 0


def candidate_samples_match_apk(path, audited_apk, device_fingerprint,
                                evidence_root, identity=None):
    return samples_match_live_probes(path, 'candidate', audited_apk,
                                     device_fingerprint, evidence_root, identity)


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
    physical_devices = live_physical_devices(serials)
    checks['physical_device_serials'] = list(physical_devices)
    audited_apk = audited_android_candidate(evidence_root, identity)
    if audited_apk is None and run_android and checks['native_sdk'] and serials:
        run_id = time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8]
        android_root = evidence_root / 'runs' / run_id / 'android'
        result = command(sys.executable, 'tool/android_release_checks.py',
                         '--all-targets', '--emulators-only', '--output', str(android_root))
        checks['android_runner_exit'] = result.returncode
        # stdout/stderr may contain media URLs; store only the exit status.
        if result.returncode:
            errors.append('Current candidate Android device runner failed')
        else:
            result_file = android_root / 'result.json'
            apk_file = android_root / 'app-probe.apk'
            if result_file.is_file() and apk_file.is_file():
                observed = json.loads(result_file.read_text(encoding='utf-8'))
                manifest = {'candidate_head': identity['head'],
                            'working_tree_sha256': identity['working_tree_sha256'],
                            'result_path': result_file.relative_to(evidence_root).as_posix(),
                            'result_sha256': sha256(result_file),
                            'apk_path': apk_file.relative_to(evidence_root).as_posix(),
                            'apk_sha256': observed.get('app_apk', {}).get('sha256')}
                (evidence_root / 'candidate-build.json').write_text(
                    json.dumps(manifest, indent=2), encoding='utf-8')
                audited_apk = audited_android_candidate(evidence_root, identity)
    if audited_apk is None:
        errors.append('Current candidate audited Android APK and three-device result missing')
    else:
        checks['audited_apk'] = audited_apk
    physical_path = evidence_root / 'physical-phone.json'
    try:
        physical = json.loads(physical_path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        physical = None
    physical_serial = physical.get('device_serial') if isinstance(physical, dict) else None
    errors.extend(validate_physical(physical, identity, evidence_root,
                                    audited_apk=audited_apk,
                                    live_device=physical_devices.get(physical_serial)))
    baseline = evidence_root / 'baseline.jsonl'
    candidate = evidence_root / 'candidate.jsonl'
    if baseline.is_file() and candidate.is_file():
        fingerprint = physical.get('device_fingerprint') if isinstance(physical, dict) else None
        if not candidate_samples_match_apk(candidate, audited_apk, fingerprint,
                                            evidence_root, identity):
            errors.append('Candidate performance samples lack audited live probe/capture provenance')
        if not samples_match_live_probes(baseline, 'baseline', audited_apk,
                                         fingerprint, evidence_root):
            errors.append('Baseline performance samples lack live probe/capture provenance')
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
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--verify-candidate', action='store_true')
    action.add_argument('--capture-scenario', choices=tuple(SCREEN_EVENTS))
    action.add_argument('--capture-performance', choices=PERFORMANCE_CATEGORIES)
    parser.add_argument('--capture-phase', choices=('before', 'after'))
    parser.add_argument('--performance-phase', choices=('baseline', 'candidate'))
    parser.add_argument('--artifact', type=Path,
                        help='Baseline APK file currently installed on the phone')
    parser.add_argument('--serial', help='Connected physical Android phone for live capture')
    parser.add_argument('--evidence-root', type=Path,
                        default=ROOT / 'build/phone-player-validation')
    args = parser.parse_args(argv)
    root = args.evidence_root.resolve()
    if args.capture_scenario or args.capture_performance:
        if not args.capture_phase or not args.serial:
            parser.error('Capture requires --capture-phase and --serial')
        if args.capture_performance and not args.performance_phase:
            parser.error('--capture-performance requires --performance-phase')
        root.mkdir(parents=True, exist_ok=True)
        identity = candidate_identity()
        if args.capture_performance and args.performance_phase == 'baseline':
            if args.artifact is None or not args.artifact.is_file():
                parser.error('Baseline capture requires an existing --artifact APK')
            audited = {'sha256': sha256(args.artifact)}
        else:
            audited = audited_android_candidate(root, identity)
        live = live_physical_devices([args.serial]).get(args.serial)
        if args.capture_performance:
            capture = capture_live_performance(root, args.capture_performance,
                                               args.capture_phase,
                                               args.performance_phase, identity,
                                               audited, live)
        else:
            capture = capture_live_screen(root, args.capture_scenario,
                                          args.capture_phase, identity, audited, live)
        if candidate_identity()['working_tree_sha256'] != identity['working_tree_sha256']:
            raise RuntimeError('Source candidate changed during live capture')
        print(json.dumps({'captured': capture['path'], 'sha256': capture['sha256'],
                          'id': capture.get('id'),
                          'scenario': args.capture_scenario or args.capture_performance,
                          'phase': args.capture_phase}))
        return 0
    result = verify_candidate(root)
    print(json.dumps({'passed': result['passed'], 'evidence': str(args.evidence_root),
                      'errors': result['errors']}, ensure_ascii=False))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())

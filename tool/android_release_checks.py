"""Android APK/AVD checks. Missing observations fail closed, with raw evidence.

Requires Pillow, grpcio and grpcio-tools for device checks (see integration_test).
Generated protobuf clients stay in build/. No host microphone is enabled.
"""
import argparse
import array
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import wave
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'com.rillight.rillight.validation'
ACTIVITY = PACKAGE + '/com.rillight.rillight.MainActivity'
ANDROID_SYSTEM_LIBRARIES = {
    'libandroid.so', 'libc.so', 'libcamera2ndk.so', 'libdl.so', 'liblog.so',
    'libm.so', 'libmediandk.so', 'libnativewindow.so',
}
CORE_LIBRARIES = {'librillight_android_core.so', 'librillight_core.so', 'libass.so'}
CORE_NOTICE_FILES = (
    'THIRD_PARTY_NOTICES.md', 'core_dependencies.json',
    'licenses/FFmpeg-LGPL-2.1.txt', 'licenses/FFmpeg-GPL-2.0.txt',
    'licenses/libass-ISC.txt', 'licenses/FreeType-LICENSE.txt',
    'licenses/FreeType-FTL.txt', 'licenses/FriBidi-LGPL-2.1.txt',
    'licenses/HarfBuzz-Old-MIT.txt',
)
ELF_MACHINES = {
    'arm64-v8a': 'AArch64',
    'armeabi-v7a': 'ARM',
    'x86_64': 'Advanced Micro Devices X86-64',
}


def run(args, **kwargs):
    return subprocess.run([str(v) for v in args], check=True, timeout=kwargs.pop('timeout', 120),
                          capture_output=True, **kwargs).stdout


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def faults(**values):
    request = urllib.request.Request('http://127.0.0.1:8784/__control', data=json.dumps(values).encode(),
                                     headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


def fixture_state():
    with urllib.request.urlopen('http://127.0.0.1:8784/__state', timeout=5) as response:
        return json.load(response)


def playback_reports(state, after_sequence):
    # __state exposes a rolling window, so use the fixture's monotonic sequence,
    # never an index into that truncated list or an earlier device's success.
    reports = [r for r in state['reports'] if r['sequence'] > after_sequence]
    accepted = {r['path'] for r in reports if r['accepted']}
    return {'passed': {'/Sessions/Playing', '/Sessions/Playing/Stopped'} <= accepted,
            'after_sequence': after_sequence, 'through_sequence': state['report_count'],
            'reports': reports}


def focused_labels(state):
    focused = [r['rect'] for r in state['rows'] if r['focused']]
    if not focused:
        return []
    x1, y1, x2, y2 = min(focused, key=lambda r: (r[2]-r[0])*(r[3]-r[1]))
    return sorted({r['label'] for r in state['rows'] if r['label'] and
                   x1 <= (r['rect'][0]+r['rect'][2])/2 <= x2 and
                   y1 <= (r['rect'][1]+r['rect'][3])/2 <= y2})


def sdk_path():
    for value in [os.environ.get('ANDROID_SDK_ROOT'), os.environ.get('ANDROID_HOME'),
                  str(Path.home() / 'AppData/Local/Android/Sdk'), str(Path.home() / 'Android/Sdk')]:
        if value and Path(value).is_dir():
            return Path(value)
    raise RuntimeError('Android SDK missing; set ANDROID_SDK_ROOT')


def readelf_path():
    candidates = sorted((sdk_path() / 'ndk').glob('*/toolchains/llvm/prebuilt/*/bin/llvm-readelf*'))
    tool = next((path for path in reversed(candidates) if path.name in ('llvm-readelf', 'llvm-readelf.exe')), None)
    if tool is None:
        raise RuntimeError('Android NDK llvm-readelf missing; native APK dependencies unverified')
    return tool


def apk_native_check(apk):
    """Audit the packaged core for every ABI supported by the Flutter engine."""
    with zipfile.ZipFile(apk) as archive:
        entries = archive.namelist()
        for entry in entries:
            if 'libmpv' in entry.lower() or 'media3' in entry.lower():
                raise RuntimeError('Legacy playback artifact in APK: ' + entry)
        for entry in entries:
            if re.fullmatch(r'classes\d*\.dex', entry):
                dex = archive.read(entry)
                if any(marker in dex for marker in (
                    b'androidx/media3/', b'androidx.media3.',
                    b'com/rillight/android_player/',
                )):
                    raise RuntimeError('Legacy Media3 player classes in APK: ' + entry)
        libraries = {}
        for entry in entries:
            match = re.fullmatch(r'lib/([^/]+)/([^/]+\.so)', entry)
            if match:
                libraries.setdefault(match[1], {})[match[2]] = entry
        active_abis = sorted(abi for abi, files in libraries.items() if 'libflutter.so' in files)
        if not active_abis:
            raise RuntimeError('APK has no Flutter engine ABI')
        core_abis = sorted(abi for abi, files in libraries.items()
                           if any(name not in ('libflutter.so', 'libapp.so') for name in files))
        unknown = set(core_abis) - ELF_MACHINES.keys()
        if unknown:
            raise RuntimeError('Unsupported packaged native ABI: ' + ', '.join(sorted(unknown)))
        for abi in core_abis:
            missing = CORE_LIBRARIES - libraries[abi].keys()
            if missing:
                raise RuntimeError(f'{abi} missing owned core libraries: {sorted(missing)}')
        if not set(active_abis) <= set(core_abis):
            raise RuntimeError('Flutter engine ABI has no owned core libraries')
        tool = readelf_path()
        audited = {}
        with tempfile.TemporaryDirectory(prefix='rillight-apk-native-') as folder:
            for abi in core_abis:
                files = libraries[abi]
                records = {}
                for name, entry in sorted(files.items()):
                    if name in ('libflutter.so', 'libapp.so'):
                        continue
                    binary = archive.read(entry)
                    target = Path(folder) / name
                    target.write_bytes(binary)
                    try:
                        details = run([tool, '-h', '-d', target]).decode('utf-8')
                    except subprocess.CalledProcessError as error:
                        raise RuntimeError(f'{abi}/{name} is not a readable ELF') from error
                    machine = next((line.partition('Machine:')[2].strip() for line in details.splitlines()
                                    if 'Machine:' in line), '')
                    if machine != ELF_MACHINES[abi]:
                        raise RuntimeError(f'{abi}/{name} has wrong ELF machine: {machine}')
                    needed = sorted(line.partition('Shared library: [')[2].partition(']')[0]
                                    for line in details.splitlines() if 'Shared library: [' in line)
                    unresolved = set(needed) - files.keys() - ANDROID_SYSTEM_LIBRARIES
                    if unresolved:
                        raise RuntimeError(f'{abi}/{name} has unresolved APK dependencies: {sorted(unresolved)}')
                    records[name] = {'sha256': hashlib.sha256(binary).hexdigest(), 'needed': needed}
                audited[abi] = records
        source_root = ROOT / 'packages/rillight_player'
        notices = {}
        for relative in CORE_NOTICE_FILES:
            asset = 'assets/rillight-core/' + relative
            if asset not in entries:
                raise RuntimeError('APK missing owned-core notice: ' + asset)
            source = source_root / ('native/' if relative != 'THIRD_PARTY_NOTICES.md' else '') / relative
            if not source.is_file() or archive.read(asset) != source.read_bytes():
                raise RuntimeError('APK owned-core notice differs from source: ' + asset)
            notices[relative] = hashlib.sha256(archive.read(asset)).hexdigest()
        return {'flutter_abis': active_abis, 'core_abis': core_abis,
                'libraries': audited, 'notice_hashes': notices}


def apk_check(apk, validation=False):
    tools = sorted((sdk_path() / 'build-tools').glob('*/aapt*'))
    aapt = next((p for p in reversed(tools) if p.name in ('aapt', 'aapt.exe')), None)
    if not aapt:
        raise RuntimeError('SDK build-tools/aapt missing')
    text = run([aapt, 'dump', 'badging', apk]).decode('utf-8')
    package = PACKAGE if validation else 'com.rillight.rillight'
    for required in [f"package: name='{package}'", "sdkVersion:'24'", "targetSdkVersion:'36'",
                     "launchable-activity: name='com.rillight.rillight.MainActivity'",
                     "leanback-launchable-activity:", "uses-permission: name='android.permission.INTERNET'"]:
        if required not in text:
            raise RuntimeError('APK contract missing: ' + required)
    if "uses-feature: name='android.hardware.touchscreen'" in text:
        raise RuntimeError('Touchscreen must not be required')
    if "uses-feature: name='android.software.leanback'" in text:
        raise RuntimeError('Leanback must not be required for phone installation')
    with apk.open('rb') as stream:
        hasher = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(chunk)
        digest = hasher.hexdigest()
    return {'sha256': digest, 'package': package, 'badging': text,
            'native': apk_native_check(apk)}


def pixel_check(first, second):
    from PIL import Image, ImageChops, ImageStat
    a, b = Image.open(first).convert('RGB'), Image.open(second).convert('RGB')
    if a.size != b.size:
        raise RuntimeError('Frame dimensions changed during pixel comparison')
    w, h = a.size
    # Exclude controls, subtitles and system bars. Portrait uses a narrow strip
    # within letterboxed video; landscape includes more of the moving pattern.
    top, bottom = (.22, .60) if w > h else (.44, .56)
    crop = (int(w * .15), int(h * top), int(w * .85), int(h * bottom))
    a, b = a.crop(crop), b.crop(crop)
    delta = sum(ImageStat.Stat(ImageChops.difference(a, b)).mean) / 3
    colors = sum(max(p) - min(p) > 35 for p in a.get_flattened_data()) / (a.width * a.height)
    if delta < 2 or colors < .1:
        raise RuntimeError(f'No changing colored video: delta={delta:.3f}, colored={colors:.3f}')
    return {'mean_rgb_difference': delta, 'colored_fraction': colors, 'crop': crop}


def reconnect_pixel_check(device):
    # Retain the first post-reconnect image, including a possible black
    # transition, and wait for two colored frames with actual motion.
    first = device.screenshot('native-surface-reconnected-audio-capture')
    for _ in range(8):
        time.sleep(.75)
        second = device.screenshot('native-moving-b')
        try:
            return pixel_check(first, second)
        except RuntimeError:
            first = second
    raise RuntimeError('No changing colored video after Surface reconnect')


def recovered_search_row(device, tv):
    if tv:
        # TV cards identify the media item by key; their title is painted
        # outside the semantics label on this layout.
        return device.row(key='movie-01')
    return device.row(label='Rillight 流光验证 01')


def audio_metrics(pcm, rate, seconds):
    samples = array.array('h', pcm)
    if sys.byteorder != 'little':
        samples.byteswap()
    duration = len(pcm) / (rate * 4)
    rms = math.sqrt(sum(v * v for v in samples) / max(1, len(samples)))
    return {'duration_seconds': duration, 'sample_rate': rate, 'rms': rms,
            'peak': max((abs(v) for v in samples), default=0),
            'passed': duration >= seconds * .85 and duration <= seconds * 1.3 and rms > 5}


def capture_audio(serial, output, rate, seconds=6):
    import grpc
    import grpc_tools
    generated = ROOT / 'build/android-validation/grpc'
    generated.mkdir(parents=True, exist_ok=True)
    proto = sdk_path() / 'emulator/lib/emulator_controller.proto'
    run([sys.executable, '-m', 'grpc_tools.protoc', '-I' + str(proto.parent),
         '-I' + str(Path(grpc_tools.__file__).parent / '_proto'),
         '--python_out=' + str(generated), '--grpc_python_out=' + str(generated), proto])
    sys.path.insert(0, str(generated))
    import emulator_controller_pb2 as pb
    import emulator_controller_pb2_grpc as rpc
    discovery = None
    candidates = [Path(tempfile.gettempdir()) / 'avd/running',
                  Path(os.environ.get('XDG_RUNTIME_DIR', '/run/user/' + str(getattr(os, 'getuid', lambda: 0)()))) / 'avd/running']
    for directory in candidates:
        for ini in directory.glob('*.ini'):
            fields = dict(line.split('=', 1) for line in ini.read_text().splitlines() if '=' in line)
            if fields.get('port.serial') == serial.removeprefix('emulator-'):
                discovery = fields
    if not discovery or not discovery.get('grpc.token'):
        raise RuntimeError('Audio unverified: start AVD with -grpc PORT -grpc-use-token')
    channel = grpc.insecure_channel('127.0.0.1:' + discovery['grpc.port'])
    grpc.channel_ready_future(channel).result(timeout=5)
    metadata = [('authorization', 'Bearer ' + discovery['grpc.token'])]
    stub = rpc.EmulatorControllerStub(channel)
    stub.setMicrophoneState(pb.MicrophoneState(realAudioEnabled=False), metadata=metadata, timeout=5)
    chunks = []
    request = pb.AudioFormat(samplingRate=rate, channels=pb.AudioFormat.Stereo, format=pb.AudioFormat.AUD_FMT_S16)
    # Software-rendered AVDs can emit virtual PCM slower than wall time. Give
    # the emulator time to produce the requested sample count, then check the
    # actual PCM duration; a timeout still fails the observation.
    stream = stub.streamAudio(request, metadata=metadata, timeout=max(seconds * 3, 15))
    started = time.monotonic()
    target_bytes = int(rate * 4 * seconds)
    received_bytes = 0
    try:
        for packet in stream:
            if packet.format.samplingRate != rate or packet.format.channels != request.channels or packet.format.format != request.format:
                raise RuntimeError('Unexpected PCM format')
            chunks.append(packet.audio)
            received_bytes += len(packet.audio)
            if received_bytes >= target_bytes:
                break
    except grpc.RpcError as error:
        if error.code() != grpc.StatusCode.DEADLINE_EXCEEDED:
            raise RuntimeError('Emulator audio RPC failed: ' + error.code().name) from None
    finally:
        channel.close()
    pcm = b''.join(chunks)
    with wave.open(str(output.with_suffix('.wav')), 'wb') as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(pcm)
    result = audio_metrics(pcm, rate, seconds)
    result.update(source='EmulatorController.streamAudio', channels=2,
                  requested_seconds=seconds, elapsed_seconds=time.monotonic()-started,
                  packet_count=len(chunks), host_microphone_enabled=False,
                  physical_audio_verified=False)
    save(output.with_suffix('.json'), result)
    if not result['passed']:
        raise RuntimeError('Virtual audio missing, silent or truncated; see audio.json')
    return result


class Device:
    def __init__(self, serial, output):
        self.serial, self.output = serial, output
        self.adb_path = sdk_path() / ('platform-tools/adb.exe' if os.name == 'nt' else 'platform-tools/adb')

    def adb(self, *args, **kwargs):
        return run([self.adb_path, '-s', self.serial, *args], **kwargs)

    def key(self, *codes):
        for code in codes:
            self.adb('shell', 'input', 'keyevent', str(code))
            with (self.output / 'inputs.jsonl').open('a', encoding='utf-8') as stream:
                stream.write(json.dumps({'keys': [code]}) + '\n')
            time.sleep(.3)

    def close_editor(self):
        # Android TV's IME Done action reaches TextField.onSubmitted and closes
        # the Flutter dialog. Repeated Back can leave the IME/dialog mounted.
        self.key(66)
        for _ in range(10):
            if not any(r['key'] == 'tv-input-editor' for r in self.state()['rows']):
                return
            time.sleep(.2)
        for _ in range(3):
            if not any(r['key'] == 'tv-input-editor' for r in self.state()['rows']):
                return
            self.key(4)
            time.sleep(.4)
        self.wait(lambda s: not any(r['key'] == 'tv-input-editor' for r in s['rows']), 'remote input dialog closed')

    def hide_ime(self):
        # A hardware-keyboard AVD may accept text without showing an IME.
        # Sending Back unconditionally would then exit the connection page.
        if b'mInputShown=true' in self.adb('shell', 'dumpsys', 'input_method'):
            self.key(4)

    def tv_destination(self, label):
        navigation = ['首页', '片库', '搜索', '设置']
        # Directional focus chooses the geometrically nearest rail entry; a
        # restored/scrolled card need not land on Home after one Left.
        for _ in range(8):
            focus = focused_labels(self.state())
            if len(focus) == 1 and focus[0] in navigation:
                break
            self.key(21)
        else:
            raise RuntimeError('TV navigation rail is unreachable with Left')
        current = navigation.index(focus[0])
        target = navigation.index(label)
        for _ in range(abs(target-current)):
            self.key(20 if target > current else 19)
        self.wait(lambda s: focused_labels(s) == [label], 'remote destination focus: ' + label)
        self.key(23, 22)

    def state(self):
        with urllib.request.urlopen('http://127.0.0.1:18799/state', timeout=4) as response:
            return json.load(response)

    def wait(self, predicate, name, seconds=25):
        deadline = time.monotonic() + seconds
        latest = None
        while time.monotonic() < deadline:
            try:
                latest = self.state()
                if predicate(latest):
                    return latest
            except (OSError, ValueError):
                pass
            time.sleep(.25)
        save(self.output / 'failed-state.json', latest)
        raise RuntimeError('Device timeout: ' + name)

    def row(self, key=None, label=None):
        state = self.wait(lambda s: any((r['key'] == key if key else r['label'] == label) for r in s['rows']), key or label)
        return state, next(r for r in state['rows'] if (r['key'] == key if key else r['label'] == label))

    def tap(self, key=None, label=None):
        state, row = self.row(key, label)
        # Display metrics change before the route finishes laying out after
        # rotation. Wait for a stable target before dispatching the one tap.
        for _ in range(20):
            time.sleep(.2)
            current_state, current_row = self.row(key, label)
            stable = current_row['rect'] == row['rect'] and current_state['size'] == state['size']
            state, row = current_state, current_row
            if stable:
                break
        else:
            raise RuntimeError('Tap target did not settle: ' + str(key or label))
        x1, y1, x2, y2 = row['rect']
        point = [round((x1+x2)/2*state['scale']), round((y1+y2)/2*state['scale'])]
        with (self.output / 'inputs.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps({'tap': point, 'key': key, 'label': label}, ensure_ascii=False) + '\n')
        self.adb('shell', 'input', 'tap', *point)
        time.sleep(.35)

    def text(self, value):
        if not re.fullmatch(r'[A-Za-z0-9:/.\-]+', value):
            raise ValueError('Only synthetic safe ASCII text is allowed')
        # EditableText mounts before Android finishes installing its input
        # connection. Injecting during that transition can overwrite the first
        # character on the TV IME, unlike normal paced keyboard input.
        time.sleep(1)
        self.adb('shell', 'input', 'text', value)
        time.sleep(.4)

    def screenshot(self, name):
        path = self.output / (name + '.png')
        path.write_bytes(self.adb('exec-out', 'screencap', '-p'))
        return path

    def logs(self):
        pid = self.adb('shell', 'pidof', PACKAGE).decode().strip()
        if not pid:
            raise RuntimeError('Validation process unavailable for log capture')
        (self.output / 'logcat.log').write_bytes(self.adb('logcat', '-d', '--pid=' + pid, '-t', '500'))

    def launch(self, apk):
        apk_check(apk, validation=True)
        self.adb('install', '--no-streaming', '-r', apk)
        # This fixed, validation-only package is deliberately disposable.
        self.adb('shell', 'am', 'force-stop', PACKAGE)
        self.adb('shell', 'pm', 'clear', PACKAGE)
        self.adb('shell', 'am', 'start', '-W', '-n', ACTIVITY)


def app_flow(device, tv):
    d = device
    d.wait(lambda s: s['tv'] == tv and not s['authenticated'], 'platform connection page')
    if tv:
        # Device navigation and confirmation use actual Android key dispatch.
        # IME typing is injected text in this automated run; the separate manual
        # OSK-only protocol/evidence must not be claimed by this check.
        for value in ['http://127.0.0.1:8784', 'mobile', 'test-only']:
            d.key(23)
            d.row(key='tv-input-editor')
            d.text(value)
            d.close_editor()  # first Back hides IME; second closes dialog
            d.key(20)
        d.key(20, 23)
    else:
        for name, value in [('address', 'http://127.0.0.1:8784'), ('username', 'mobile'), ('password', 'test-only')]:
            d.tap(key='android-connect-' + name)
            d.text(value)
            d.hide_ime()
        d.screenshot('connection-filled')
        d.adb('shell', 'uiautomator', 'dump', '/sdcard/rillight-validation.xml')
        tree = d.adb('shell', 'cat', '/sdcard/rillight-validation.xml')
        (d.output / 'connection-tree.xml').write_bytes(tree)
        if b'http://127.0.0.1:8784' not in tree or b'mobile' not in tree:
            raise RuntimeError('Synthetic login fields did not retain injected text')
        d.tap(key='android-connect-submit')
    d.wait(lambda s: s['authenticated'] is True, 'real HTTP authentication')
    d.row(label='Rillight 流光验证 01')
    d.screenshot('home')
    source_focus = None
    if tv:
        # The featured carousel's first focusable child is an unlabeled Prev
        # control. Move to its visible Details action before confirming.
        d.key(22, 20)
        source_focus = focused_labels(d.wait(lambda s: '详情' in focused_labels(s),
                                           'featured detail focus'))
        d.key(23)
        d.wait(lambda s: 'TvDetailPage' in s['pages'], 'remote detail')
    else:
        d.tap(label='Rillight 流光验证 01')
        d.row(key='mobile-detail-play')
    if tv:
        d.key(23)
    else:
        d.tap(key='mobile-detail-play')
    d.wait(lambda s: s['player'] and not s['player']['loading'] and s['player']['playing'], 'owned core playing', 40)
    # A freshly booted Android phone shows a one-time System UI immersive-mode
    # tutorial above the actual video. Dismiss its explicit button before the
    # displayed-pixel observation; never count the tutorial as a video frame.
    if not tv:
        d.adb('shell', 'uiautomator', 'dump', '/sdcard/rillight-player-screen.xml')
        tree = ET.fromstring(d.adb('shell', 'cat', '/sdcard/rillight-player-screen.xml'))
        for node in tree.iter('node'):
            if node.attrib.get('package') != 'com.android.systemui' or \
                    node.attrib.get('text') not in ('Got it', '知道了'):
                continue
            bounds = [int(value) for value in re.findall(r'\d+', node.attrib.get('bounds', ''))]
            if len(bounds) != 4:
                continue
            x1, y1, x2, y2 = bounds
            d.adb('shell', 'input', 'tap', (x1+x2)//2, (y1+y2)//2)
            save(d.output / 'immersive-hint.json', {'dismissed': True, 'bounds': bounds})
            break
    # Capture displayed frames before opening the emulator's audio stream.
    # That stream can trigger a separate Android audio-focus transition.
    time.sleep(1)
    first = d.screenshot('playing-a')
    time.sleep(1)
    second = d.screenshot('playing-b')
    pixels = pixel_check(first, second)
    try:
        audio = capture_audio(d.serial, d.output / 'audio', 48000 if tv else 44100)
    except Exception as error:
        # Keep independent UI/control observations, but never pass the device
        # or overall run without its required audio evidence.
        audio_file = d.output / 'audio.json'
        audio = json.loads(audio_file.read_text()) if audio_file.exists() else {'passed': False}
        audio.update(passed=False, error=str(error))
        save(audio_file, audio)
    post_audio = d.state()
    save(d.output / 'post-audio-state.json', post_audio)
    save(d.output / 'app-observations.json', {
        'virtual_audio': audio, 'displayed_pixels': pixels,
        'featured_focus': source_focus,
        'playing_after_audio_capture': bool(post_audio['player'] and post_audio['player']['playing']),
    })
    if not post_audio['player'] or not post_audio['player']['playing']:
        raise RuntimeError('Playback paused during emulator virtual-audio capture; see post-audio-state.json')
    if tv:
        d.key(85)
    else:
        state = d.state()
        if not state['player']['controls']:
            d.adb('shell', 'input', 'tap', round(state['size'][0]/2), round(state['size'][1]/2))
        d.tap(key='mobile-player-toggle')
    d.wait(lambda s: s['player'] and not s['player']['playing'], 'pause')
    time.sleep(.5)
    position = d.state()['player']['positionMs']
    time.sleep(.7)
    if abs(d.state()['player']['positionMs'] - position) >= 300:
        raise RuntimeError('Paused clock advanced')
    if not tv:
        old = {name: d.adb('shell', 'settings', 'get', 'system', name).decode().strip()
               for name in ['accelerometer_rotation', 'user_rotation']}
        try:
            d.adb('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
            d.adb('shell', 'settings', 'put', 'system', 'user_rotation', '1')
            d.wait(lambda s: s['size'][0] > s['size'][1] and s['player'] and not s['player']['playing'], 'landscape preserves paused player')
            d.screenshot('landscape-paused')
        finally:
            for name, value in old.items():
                if value == 'null':
                    d.adb('shell', 'settings', 'delete', 'system', name)
                else:
                    d.adb('shell', 'settings', 'put', 'system', name, value)
        d.wait(lambda s: s['size'][0] > s['size'][1] and s['player'] and
               not s['player']['playing'], 'player retains landscape lock')
    if tv:
        d.key(85)
    else:
        d.tap(key='mobile-player-toggle')
    d.wait(lambda s: s['player'] and s['player']['playing'], 'resume')
    d.key(3)
    time.sleep(2)
    d.adb('shell', 'am', 'start', '-n', ACTIVITY)
    d.wait(lambda s: s['player'] and not s['player']['loading'] and not s['player']['released'] and not s['player']['playing'], 'foreground restores paused', 40)
    d.screenshot('foreground-paused')
    if tv:
        d.key(22, 4)
        d.wait(lambda s: s['player'] is not None, 'first Back only hides controls')
        d.key(4)
    else:
        d.key(4)
    d.wait(lambda s: s['player'] is None and any(p.endswith('DetailPage') for p in s['pages']), 'Back returns detail')
    if not tv:
        d.wait(lambda s: s['size'][1] > s['size'][0], 'detail restores portrait')
    d.screenshot('detail-return')
    d.key(4)
    d.wait(lambda s: any(p.endswith('Shell') for p in s['pages']) and
           not any(p.endswith('DetailPage') for p in s['pages']) and s['player'] is None,
           'Back returns catalog after route transition')
    if tv:
        d.wait(lambda s: focused_labels(s) == source_focus, 'restore exact source card focus')
    d.screenshot('source-return')
    # A real failed HTTP search, then retry, exercises fixture injection and UI.
    faults(offline=True)
    try:
        if tv:
            d.tv_destination('搜索')
            d.key(23)
            d.row(key='tv-input-editor')
            d.text('Rillight')
            d.close_editor()
        else:
            d.tap(label='搜索')
            d.tap(key='mobile-search-field')
            d.text('Rillight')
            d.hide_ime()
        d.row(label='重试')
        d.screenshot('search-offline')
    finally:
        faults(offline=False)
    if tv:
        for _ in range(5):
            if '重试' in focused_labels(d.state()):
                break
            d.key(20)
        else:
            raise RuntimeError('TV retry action could not receive remote focus')
        d.key(23)
    else:
        d.tap(label='重试')
    recovered_search_row(d, tv)
    d.screenshot('search-recovered')
    return {'pixels': pixels, 'virtual_audio': audio, 'control_flow': True,
            'search_fault_recovery': True, 'rotation': True if not tv else 'not-applicable',
            'tv_native_remote_navigation': tv, 'tv_osk_only': False if tv else None}


def native_flow(d, apk, tv):
    with urllib.request.urlopen('http://127.0.0.1:8865/__checks', timeout=5) as response:
        before = json.load(response)
    d.launch(apk)
    pid = ''
    for _ in range(40):
        try:
            pid = d.adb('shell', 'pidof', PACKAGE).decode().strip()
            if pid:
                break
        except subprocess.CalledProcessError:
            pass
        time.sleep(.25)
    if not pid:
        raise RuntimeError('Native smoke process failed to start')
    deadline = time.monotonic() + 150
    captured = set()
    result = {}
    while time.monotonic() < deadline:
        log = d.adb('logcat', '-d', '--pid=' + pid, '-s', 'flutter:D', '*:S').decode('utf-8', errors='replace')
        (d.output / 'native.log').write_text(log, encoding='utf-8')
        if 'RILLIGHT_ANDROID_SMOKE_FAIL' in log:
            raise RuntimeError('Native controls failed; see native.log')
        for stage in ['embedded-subtitle', 'external-srt', 'external-vtt', 'surface-reconnected-audio-capture']:
            if '"stage":"' + stage + '"' in log and stage not in captured:
                captured.add(stage)
                if stage == 'surface-reconnected-audio-capture':
                    result['pixels'] = reconnect_pixel_check(d)
                    # App flow owns audio evidence. This separate entrypoint
                    # asserts controls; it must not claim a second capture.
                    result['virtual_audio'] = 'not captured here; see app flow'
                else:
                    d.screenshot('native-' + stage)
        if 'RILLIGHT_ANDROID_SMOKE_PASS' in log:
            if len(captured) != 4 or not result:
                raise RuntimeError('Native smoke passed without all output observations')
            with urllib.request.urlopen('http://127.0.0.1:8865/__checks', timeout=5) as response:
                after = json.load(response)
            result['http_delta'] = {key: after[key] - before[key] for key in before}
            if after['leaks'] or any(result['http_delta'][key] <= 0 for key in ('authorized', 'cross_origin')):
                raise RuntimeError('This device did not independently pass HTTP credential boundaries')
            result['controls'] = True
            return result
        time.sleep(.2)
    raise RuntimeError('Native smoke terminal marker missing')


def build(entry, output, validation):
    environment = os.environ.copy()
    environment.pop('ORG_GRADLE_PROJECT_rillightValidation', None)
    if validation:
        environment['ORG_GRADLE_PROJECT_rillightValidation'] = 'true'
    command = [shutil.which('flutter') or 'flutter', 'build', 'apk', '--debug', '-t', entry]
    command += ['--android-project-arg=rillightValidation=' + str(validation).lower()]
    if 'android_player_smoke' in entry:
        command += ['--dart-define=ANDROID_SMOKE_HOLD_SECONDS=20', '--dart-define=ANDROID_SMOKE_BASE=http://127.0.0.1:8865/']
    process = subprocess.run(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, timeout=600)
    output.with_suffix('.build.log').write_bytes(process.stdout)
    process.check_returncode()
    shutil.copyfile(ROOT / 'build/app/outputs/flutter-apk/app-debug.apk', output)
    save(output.with_suffix('.apk.json'), apk_check(output, validation))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--all-targets', action='store_true')
    parser.add_argument('--native-only', action='store_true',
                        help='Run the owned-core native smoke without the catalog UI flow')
    parser.add_argument('--serial')
    parser.add_argument('--apk', type=Path, help='Audit a normal production APK only')
    parser.add_argument('--app-apk', type=Path, help='Reuse an explicitly supplied validation observer APK')
    parser.add_argument('--native-apk', type=Path, help='Reuse validation native smoke APK (port 8865)')
    parser.add_argument('--media', type=Path, default=ROOT / 'build/android-validation/media')
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = args.output or ROOT / 'build/android-validation/runs' / time.strftime('%Y%m%d-%H%M%S')
    output.mkdir(parents=True, exist_ok=False)
    result = {'passed': False, 'devices': [], 'physical_audio': 'unverified', 'hardware_gpu': 'unverified'}
    result['source'] = {'head': run(['git', '-C', ROOT, 'rev-parse', 'HEAD']).decode().strip(),
                        'dirty': bool(run(['git', '-C', ROOT, 'status', '--porcelain']).strip())}
    server = None
    native_server = None
    server_log = native_log = None
    try:
        if args.apk:
            result['apk'] = apk_check(args.apk)
        else:
            adb = sdk_path() / ('platform-tools/adb.exe' if os.name == 'nt' else 'platform-tools/adb')
            serials = [args.serial] if args.serial else [line.split()[0] for line in run([adb, 'devices']).decode().splitlines()
                                                       if len(line.split()) == 2 and line.split()[1] == 'device']
            if not serials:
                raise RuntimeError('Devices unavailable; device/audio checks unverified')
            devices = []
            for serial in serials:
                folder = output / serial
                folder.mkdir()
                d = Device(serial, folder)
                tv = b'android.software.leanback' in d.adb('shell', 'pm', 'list', 'features')
                size = re.findall(r'(\d+)x(\d+)', d.adb('shell', 'wm', 'size').decode())[-1]
                density = int(re.findall(r'\d+', d.adb('shell', 'wm', 'density').decode())[-1])
                width = round(min(map(int, size)) * 160 / density)
                devices.append((d, tv, width))
            if args.all_targets and not (any(tv for _, tv, _ in devices) and all(any(not tv and abs(width-target) <= 2 for _, tv, width in devices) for target in (360, 412))):
                raise RuntimeError('Required AVD coverage unavailable: phone 360dp, phone 412dp, TV')
            if not (args.media / 'android-tracks.mkv').exists():
                run([sys.executable, ROOT / 'tool/android_fixtures.py', '--generate', '--media', args.media, '--ffmpeg', args.ffmpeg], timeout=240)
            server_log = (output / 'fixture.log').open('wb')
            server = subprocess.Popen([sys.executable, str(ROOT / 'tool/android_fixtures.py'), '--media', str(args.media), '--output', str(output / 'fixture')], stdout=server_log, stderr=subprocess.STDOUT)
            for _ in range(50):
                if server.poll() is not None:
                    raise RuntimeError('Synthetic fixture could not start (port 8784 must be free)')
                if (output / 'fixture/server.json').exists():
                    break
                time.sleep(.1)
            app = None if args.native_only else (args.app_apk or output / 'app-probe.apk')
            if app is not None and not args.app_apk:
                build('integration_test/android_app_probe.dart', app, True)
            native = args.native_apk or output / 'native-smoke.apk'
            if not args.native_apk:
                build('integration_test/android_player_smoke.dart', native, True)
            if app is not None:
                result['app_apk'] = apk_check(app, True)
            result['native_apk'] = apk_check(native, True)
            native_log = (output / 'native-fixture.log').open('wb')
            native_server = subprocess.Popen([sys.executable, str(ROOT / 'integration_test/android/smoke_server.py'),
                str(args.media), '--port', '8865', '--remote-port', '8866'], stdout=native_log, stderr=subprocess.STDOUT)
            time.sleep(.5)
            if native_server.poll() is not None:
                raise RuntimeError('Native fixture ports 8865/8866 unavailable')
            for d, tv, width in devices:
                row = {'serial': d.serial, 'tv': tv, 'width_dp': width, 'passed': False}
                row['android_api'] = d.adb('shell', 'getprop', 'ro.build.version.sdk').decode().strip()
                row['abi'] = d.adb('shell', 'getprop', 'ro.product.cpu.abi').decode().strip()
                row['image_fingerprint'] = d.adb('shell', 'getprop', 'ro.build.fingerprint').decode().strip()
                row['avd_name'] = d.adb('shell', 'getprop', 'ro.boot.qemu.avd_name').decode().strip()
                result['devices'].append(row)
                try:
                    d.adb('reverse', 'tcp:8784', 'tcp:8784')
                    d.adb('reverse', 'tcp:8865', 'tcp:8865')
                    d.adb('reverse', 'tcp:8866', 'tcp:8866')
                    d.adb('forward', 'tcp:18799', 'tcp:8799')
                    if app is not None:
                        report_start = fixture_state()['report_count']
                        d.launch(app)
                        try:
                            row.update(app_flow(d, tv))
                        except Exception as error:
                            row['app_error'] = str(error)
                        row['playback_reports'] = playback_reports(fixture_state(), report_start)
                        save(d.output / 'playback-reports.json', row['playback_reports'])
                    try:
                        row['native'] = native_flow(d, native, tv)
                    except Exception as error:
                        row['native_error'] = str(error)
                    row['passed'] = ('native_error' not in row and row.get('native', {}).get('controls') is True)
                    if app is not None:
                        row['passed'] = (row['passed'] and 'app_error' not in row and
                            row.get('virtual_audio', {}).get('passed') is True and
                            row['playback_reports']['passed'])
                    if not row['passed']:
                        row['error'] = row.get('app_error') or row.get('native_error') or (
                            'This device has no accepted Playing/Stopped report pair'
                        )
                except Exception as error:
                    row['error'] = str(error)
                finally:
                    # Cleanup diagnostics must not hide the original failure.
                    for cleanup in [lambda: d.screenshot('final'),
                                    d.logs,
                                    lambda: d.adb('shell', 'am', 'force-stop', PACKAGE),
                                    lambda: d.adb('forward', '--remove', 'tcp:18799'),
                                    lambda: d.adb('reverse', '--remove', 'tcp:8784'),
                                    lambda: d.adb('reverse', '--remove', 'tcp:8865'),
                                    lambda: d.adb('reverse', '--remove', 'tcp:8866')]:
                        try:
                            cleanup()
                        except Exception as error:
                            row.setdefault('cleanup_errors', []).append(str(error))
            save(output / 'fixture-final.json', fixture_state())
        result['passed'] = bool(args.apk) or bool(result['devices']) and all(row['passed'] for row in result['devices'])
        if not result['passed']:
            result['error'] = 'One or more devices failed; inspect individual evidence'
    except Exception as error:
        result['error'] = str(error)
    finally:
        if server:
            server.terminate()
            server.wait(timeout=10)
        if native_server:
            native_server.terminate()
            native_server.wait(timeout=10)
        for log in (server_log, native_log):
            if log is not None:
                log.close()
        if not args.apk and not args.native_only and (not args.app_apk or not args.native_apk):
            try:
                build('lib/main.dart', output / 'rillight-debug.apk', False)
            except Exception as error:
                result['passed'] = False
                result['restore_error'] = str(error)
        save(output / 'result.json', result)
    print(json.dumps({'passed': result['passed'], 'evidence': str(output), 'error': result.get('error')}, ensure_ascii=False))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

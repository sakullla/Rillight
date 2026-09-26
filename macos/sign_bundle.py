"""Sign nested code without app entitlements, then the app with Release rights."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

RELEASE = Path(__file__).resolve().parent / 'Runner/Release.entitlements'
REQUIRED = ('com.apple.security.app-sandbox',
            'com.apple.security.network.client', 'com.apple.security.network.server')


def release_entitlements(path=RELEASE):
    expected = plistlib.loads(Path(path).read_bytes())
    if any(expected.get(key) is not True for key in REQUIRED):
        raise ValueError('Release must retain sandbox, network client and network server')
    return expected


def verify_signed_entitlements(app, expected):
    # Read the signature itself; checking the source plist or codesign's exit
    # status alone cannot detect entitlements lost during the final re-sign.
    encoded = subprocess.check_output(
        ['codesign', '--display', '--entitlements', ':-', str(app)])
    actual = plistlib.loads(encoded)
    if actual != expected:
        raise ValueError(f'Signed entitlements differ: expected {expected}, got {actual}')
    return actual


def sign(app, *, identity=None, without_server_for_test=False):
    app = Path(app).resolve()
    if app.suffix != '.app' or not (app / 'Contents/MacOS').is_dir():
        raise ValueError('Expected an existing .app bundle')
    signer = identity or '-'
    expected = release_entitlements()
    if without_server_for_test:
        expected.pop('com.apple.security.network.server')
    frameworks = app / 'Contents/Frameworks'
    nested = list(frameworks.rglob('*.dylib')) + list(frameworks.rglob('*.framework'))
    seen = set()
    for path in sorted(nested, key=lambda p: len(p.parts), reverse=True):
        canonical = path.resolve()
        if canonical in seen:
            continue
        seen.add(canonical)
        subprocess.check_call(['codesign', '--force', '--sign', signer,
                               '--timestamp=none', str(path)])
    record_path = app / 'Contents/Resources/rillight-macos-closure.json'
    if not record_path.is_file():
        raise ValueError('Missing owned-core macOS closure record before signing')
    record = json.loads(record_path.read_text(encoding='utf-8'))
    libraries = record.get('libraries')
    if not isinstance(libraries, dict) or 'librillight_core.dylib' not in libraries:
        raise ValueError('Owned-core closure record is incomplete')
    final_hashes = {}
    for name in libraries:
        path = frameworks / name
        if not path.is_file():
            raise ValueError('Missing owned-core release dylib: ' + name)
        final_hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    record['final_libraries_sha256'] = final_hashes
    record_path.write_text(json.dumps(record, ensure_ascii=False,
                                      sort_keys=True, indent=2) + '\n',
                           encoding='utf-8')
    with tempfile.TemporaryDirectory(prefix='rillight-entitlements-') as directory:
        entitlements = Path(directory) / 'Release.entitlements'
        entitlements.write_bytes(plistlib.dumps(expected))
        # No --deep here: app sandbox/network rights belong to the executable,
        # not every dylib/framework bundled into the application.
        subprocess.check_call(['codesign', '--force', '--sign', signer, '--timestamp=none',
                               '--entitlements', str(entitlements), str(app)])
    displayed = subprocess.check_output(
        ['codesign', '--display', '--verbose=4', str(app)], stderr=subprocess.STDOUT,
        text=True)
    if identity is None:
        if 'Signature=adhoc' not in displayed.splitlines():
            raise ValueError('Expected the explicit ad-hoc distribution signature')
    elif f'Authority={identity}' not in displayed:
        raise ValueError(f'Expected the distribution signature of {identity}')
    subprocess.check_call(['codesign', '--verify', '--deep', '--strict', str(app)])
    verify_signed_entitlements(app, expected)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app')
    parser.add_argument('--identity', default=None,
                        help='Code-signing identity name; omit it for an ad-hoc signature')
    parser.add_argument('--without-server-for-test', action='store_true',
                        help='Negative sandbox regression only; never a release artifact')
    args = parser.parse_args()
    sign(args.app, identity=args.identity,
         without_server_for_test=args.without_server_for_test)

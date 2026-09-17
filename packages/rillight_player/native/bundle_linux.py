"""Copy a built prefix's shared media libraries into a Flutter Linux bundle.

Usage: python3 bundle_linux.py PREFIX BUNDLE
System GL/audio/font dependencies remain distribution runtime prerequisites.
"""
from pathlib import Path
import shutil
import subprocess
import sys

prefix, bundle = (Path(value).resolve() for value in sys.argv[1:3])
destination = bundle / 'lib'
destination.mkdir(parents=True, exist_ok=True)
libraries = sorted((prefix / 'lib').glob('*.so*'))
if not any(path.name == 'libmpv.so.2' for path in libraries):
    raise RuntimeError('Prefix has no libmpv.so.2; use the source build prefix')
for source in libraries:
    if source.is_file():
        target = destination / source.name
        shutil.copyfile(source.resolve(), target)
        subprocess.check_call(['patchelf', '--set-rpath', '$ORIGIN', str(target)])
report = prefix / 'rillight-source-versions.txt'
for plugin in destination.glob('*rillight_player*.so'):
    subprocess.check_call(['patchelf', '--set-rpath', '$ORIGIN', str(plugin)])
if report.exists():
    shutil.copyfile(report, bundle / report.name)
root = Path(__file__).resolve().parent.parent
notices = bundle / 'data/rillight_player'
notices.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / 'native/dependencies.json', notices / 'dependencies.json')
shutil.copyfile(root / 'THIRD_PARTY_NOTICES.md', notices / 'THIRD_PARTY_NOTICES.md')
shutil.copytree(root / 'native/licenses', notices / 'licenses', dirs_exist_ok=True)
print('Bundled', len(libraries), 'media library names into', destination)

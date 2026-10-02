"""Generate an out-of-tree Meson adapter for pinned libunibreak 6.1.

The upstream source (including its generated Unicode tables) stays unchanged.
These are precisely the library translation units in upstream src/Makefile.am;
no network-based Unicode table generation is performed during the build.
"""
from pathlib import Path

SOURCES = ('unibreakbase.c', 'unibreakdef.c', 'linebreak.c', 'linebreakdata.c',
           'linebreakdef.c', 'eastasianwidthdef.c', 'emojidef.c',
           'graphemebreak.c', 'wordbreak.c')
HEADERS = ('unibreakbase.h', 'unibreakdef.h', 'linebreak.h', 'linebreakdef.h',
           'eastasianwidthdef.h', 'graphemebreak.h', 'wordbreak.h')


def meson_source(source: Path, destination: Path, version: str) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    def literal(path: Path) -> str:
        return "'" + path.as_posix().replace("'", "\\'") + "'"
    files = ',\n'.join(literal(source / 'src' / name) for name in SOURCES)
    headers = ',\n'.join(literal(source / 'src' / name) for name in HEADERS)
    (destination / 'meson.build').write_text(
        f"project('libunibreak', 'c', version: '{version}')\n"
        f"unibreak = static_library('unibreak', files({files}),\n"
        "  pic: true, install: true)\n"
        f"install_headers({headers})\n"
        "import('pkgconfig').generate(unibreak, name: 'libunibreak',\n"
        "  filebase: 'libunibreak', description: 'Unicode line breaking',\n"
        "  version: meson.project_version())\n", encoding='utf-8')
    return destination

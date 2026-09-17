"""Assert that the visible Zenity process exposes the missing-core explanation."""
import json
from pathlib import Path
import sys
import time

import pyatspi

pid = int(sys.argv[1])
output = Path(sys.argv[2])
observed = []

def collect(node, depth=0):
    if depth > 20:
        return []
    values = [node.name] if node.name else []
    try:
        text = node.queryText()
        values.append(text.getText(0, text.characterCount))
    except NotImplementedError:
        pass
    for child in node:
        if child:
            values.extend(collect(child, depth + 1))
    return values

for _ in range(50):
    desktop = pyatspi.Registry.getDesktop(0)
    for app in desktop:
        if app and app.get_process_id() == pid:
            observed = collect(app)
            text = '\n'.join(observed)
            if 'libmpv.so.2' in text and '诊断日志' in text:
                output.write_text(json.dumps({'pid': pid, 'text': observed}, ensure_ascii=False, indent=2), encoding='utf-8')
                print('Visible diagnostic process exposes missing-core and log-path text')
                sys.exit(0)
    time.sleep(0.1)
output.write_text(json.dumps({'pid': pid, 'text': observed}, ensure_ascii=False, indent=2), encoding='utf-8')
raise RuntimeError('Visible dialog did not expose the missing-core explanation')

#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
git diff --check
# Audit tracked files, not worktree administrative .git pointers or build caches.
# Do not print matching contents: even a failing audit must not disclose secrets.
python3 - <<'PY'
from pathlib import Path
import re
import subprocess

paths = subprocess.check_output(['git', 'ls-files', '-z']).decode().split('\0')
private_path = re.compile(rb'/' + rb'Users/')
jwt = re.compile(rb'[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}')
forbidden = {'.chls', '.chlsz', '.trace', '.har'}
failures = []
for name in filter(None, paths):
    path = Path(name)
    if path.suffix.lower() in forbidden or path.name == '.player-config.json':
        failures.append(f'{name}: forbidden private artifact')
        continue
    if path.is_symlink():
        failures.append(f'{name}: tracked symlink requires review')
        continue
    if not path.is_file():
        continue
    data = path.read_bytes()
    if private_path.search(data) or jwt.search(data):
        failures.append(f'{name}: potential private path or JWT-like secret')
if failures:
    raise SystemExit('\n'.join(failures))
print('source verification passed (tracked files; review untracked files before staging)')
PY

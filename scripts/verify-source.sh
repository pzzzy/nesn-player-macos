#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
swift build -c release
git diff --check
if grep -RIE '/Users/|[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}' --exclude-dir=.git --exclude-dir=.build --exclude-dir=dist --exclude='verify-source.sh' --exclude='ci.yml' .; then
  print -u2 'Potential private path or JWT-like secret found.'
  exit 1
fi
for forbidden in '*.chls' '*.chlsz' '*.trace' '*.har' '.player-config.json'; do
  if find . -type f -name "$forbidden" -not -path './.git/*' | grep -q .; then
    print -u2 "Forbidden private artifact found: $forbidden"
    exit 1
  fi
done
echo 'source verification passed'

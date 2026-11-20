#!/bin/zsh
# Builds MacSweep.app, installs it into /Applications and restarts it.
set -euo pipefail
cd "$(dirname "$0")"

scripts/bundle.sh
pkill -x MacSweep && sleep 1 || true
rm -rf /Applications/MacSweep.app ~/Applications/MacSweep.app
cp -R build/MacSweep.app /Applications/
open /Applications/MacSweep.app
echo "Installed /Applications/MacSweep.app"

#!/bin/sh
# Refresh the bundled manufacturer list from Wireshark's manuf file (built from the IEEE registry).
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/manuf" https://www.wireshark.org/download/automated/data/manuf
python3 -I scripts/convert-manuf.py "$tmp/manuf" HomeNetPulse/Resources/manuf.tsv

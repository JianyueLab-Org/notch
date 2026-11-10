#!/bin/bash
# Builds, signs and zips the agent plugin into build/plugins/agents/.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(plutil -extract version raw manifest.json)
ID=$(plutil -extract id raw manifest.json)
IDENTITY="${IDENTITY:-Developer ID Application: JIANYUELAB LTD (D26JNXU8V2)}"
OUT="../../build/plugins/agents"

swift build -c release --arch arm64
rm -rf "$OUT"
mkdir -p "$OUT/$ID"
cp "$(swift build -c release --arch arm64 --show-bin-path)/agents" manifest.json "$OUT/$ID/"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$OUT/$ID/agents"
(cd "$OUT" && ditto -c -k --keepParent "$ID" "NotchNotchAgents-$VERSION.zip")
echo "$OUT/NotchNotchAgents-$VERSION.zip"

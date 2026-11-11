#!/bin/sh
# 用法: scripts/build.sh [device|sim]
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode_27_1.app/Contents/Developer
if [ "$1" = "sim" ]; then DEST='generic/platform=iOS Simulator'; else DEST='generic/platform=iOS'; fi
xcodebuild -project ARKitDemo.xcodeproj -scheme ARKitDemo -configuration Debug \
  -destination "$DEST" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E "error|warning: |BUILD (SUCCEEDED|FAILED)" | grep -v "appintents" | sort -u

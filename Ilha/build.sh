#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Ilha.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Ilha "$APP/Contents/MacOS/Ilha"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP"   # assinatura ad-hoc, suficiente para rodar localmente
echo "Pronto: $APP  (abra com: open $APP)"

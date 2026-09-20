#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
vedaCache="$(cd ../../work && pwd)/swift-cache-v3"
mkdir -p Veda.app/Contents/MacOS Veda.app/Contents/Resources
swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -module-cache-path "$vedaCache" Sources/Core.swift Sources/AudioCapture.swift Sources/Visuals.swift Sources/SnapTranslate.swift Sources/Critter.swift Sources/main.swift -o Veda.app/Contents/MacOS/Veda -framework AppKit -framework SwiftUI -framework AVFoundation -framework ApplicationServices -framework Vision -framework Translation
swift -module-cache-path "$(cd ../../work && pwd)/icon-cache" scripts/make-icon.swift ../../work/Veda.iconset
python3 scripts/package-icon.py ../../work/Veda.iconset Veda.app/Contents/Resources/Veda.icns
cat > Veda.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.veda.dictation</string>
<key>CFBundleIconFile</key><string>Veda.icns</string>
<key>CFBundleName</key><string>gluu bot</string>
<key>CFBundleDisplayName</key><string>gluu bot</string>
<key>CFBundleExecutable</key><string>Veda</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.53</string>
<key>CFBundleVersion</key><string>54</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Veda ใช้ไมโครโฟนเมื่อคุณกด Fn ค้างเพื่อถอดเสียงบนเครื่อง</string>
</dict></plist>
PLIST
if [ -d runtime ]; then
  mkdir -p Veda.app/Contents/Resources/runtime
  cp -X runtime/* Veda.app/Contents/Resources/runtime/
fi
# Sign outside File Provider folders to prevent FinderInfo racing codesign.
stage=$(mktemp -d /private/tmp/veda-sign.XXXXXX)
python3 - "$stage" <<'PY_COPY'
import shutil, sys
shutil.copytree('Veda.app', sys.argv[1] + '/Veda.app', copy_function=shutil.copyfile)
PY_COPY
chmod +x "$stage/Veda.app/Contents/MacOS/Veda" "$stage/Veda.app/Contents/Resources/runtime/whisper-server"
codesign --force --deep --sign - "$stage/Veda.app"
codesign --verify --deep --strict "$stage/Veda.app"
mv "$stage/Veda.app" "$stage/gluu bot.app"
/usr/bin/ditto -c -k --norsrc --keepParent "$stage/gluu bot.app" Veda.zip
mv "$stage/gluu bot.app" "$stage/Veda.app"
python3 - "$stage" <<'PY_COPY'
import shutil, sys
shutil.copytree(sys.argv[1] + '/Veda.app', 'Veda.app', dirs_exist_ok=True, copy_function=shutil.copyfile)
shutil.rmtree(sys.argv[1])
PY_COPY
chmod +x Veda.app/Contents/MacOS/Veda Veda.app/Contents/Resources/runtime/whisper-server
printf 'Built gluu bot.app (in Veda.zip)\n'

# Keep build products out of Spotlight / app launchers. Install only from Veda.zip.
mkdir -p ../../work/build-artifacts.noindex
python3 - <<'PY_ARCHIVE'
from pathlib import Path
import shutil
dest=Path('../../work/build-artifacts.noindex/Veda.bundle-backup')
if dest.exists(): shutil.rmtree(dest)
shutil.move('Veda.app', dest)
PY_ARCHIVE

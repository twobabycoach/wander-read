#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache dist/漫读.app/Contents/MacOS dist/漫读.app/Contents/Resources
swiftc -parse-as-library -O -module-cache-path .build/module-cache -target arm64-apple-macosx13.0 Sources/WanderRead/*.swift -o dist/漫读.app/Contents/MacOS/WanderRead
cat > dist/漫读.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>漫读</string>
<key>CFBundleDisplayName</key><string>漫读</string>
<key>CFBundleIdentifier</key><string>local.wanderread.mac</string>
<key>CFBundleExecutable</key><string>WanderRead</string>
<key>CFBundleVersion</key><string>23</string>
<key>CFBundleShortVersionString</key><string>0.9.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>漫读收藏入口</string><key>CFBundleURLSchemes</key><array><string>wanderread</string></array></dict></array>
</dict></plist>
PLIST
if [ -f Design/AppIcon.icns ]; then cp Design/AppIcon.icns dist/漫读.app/Contents/Resources/AppIcon.icns; fi
codesign --force --deep --sign - dist/漫读.app
echo "已生成：$(pwd)/dist/漫读.app"

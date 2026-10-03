#!/bin/sh
# Builds Caton.app (release) into build/. Set CATON_GITHUB_CLIENT_ID to the
# client id of a GitHub OAuth App with device flow enabled to turn on
# "Sign in with GitHub".
set -e
cd "$(dirname "$0")/.."
swift build -c release
app=build/Caton.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Caton "$app/Contents/MacOS/Caton"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.caton.Caton</string>
  <key>CFBundleName</key><string>Caton</string>
  <key>CFBundleExecutable</key><string>Caton</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>CatonGitHubClientID</key><string>${CATON_GITHUB_CLIENT_ID:-}</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"

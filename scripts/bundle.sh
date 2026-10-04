#!/bin/sh
# Builds Caton.app (release, Apple silicon) into build/.
# CATON_GITHUB_CLIENT_ID overrides the OAuth App "Sign in with GitHub" uses
# (Caton's own by default).
set -e
cd "$(dirname "$0")/.."
# Apple silicon only: macOS 26 is the last release for Intel Macs, and
# macOS warns about apps that carry Intel code.
swift build -c release --arch arm64
version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/Caton/App/AppInfo.swift)
app=build/Caton.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/arm64-apple-macosx/release/Caton "$app/Contents/MacOS/Caton"
cp -R .build/arm64-apple-macosx/release/Caton_Caton.bundle "$app/Contents/Resources/"
cp Sources/Caton/Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.caton.Caton</string>
  <key>CFBundleName</key><string>Caton</string>
  <key>CFBundleExecutable</key><string>Caton</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>CatonGitHubClientID</key><string>${CATON_GITHUB_CLIENT_ID:-Ov23liz9s5AlvZVZWZ2k}</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"

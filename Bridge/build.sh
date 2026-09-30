#!/bin/bash
# Builds SpatialPreviewBridge.app. No Xcode project, no signing identity required —
# ad-hoc signing is enough for a locally run app. If Spatial Preview turns out to
# need a real provisioning profile, that is the point to move to an .xcodeproj.
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --sdk macosx --show-sdk-path)
if [[ ! -d "$SDK/System/Library/Frameworks/SpatialPreview.framework" ]]; then
  echo "SpatialPreview.framework is not in $SDK - point xcode-select at an Xcode with the macOS 27 SDK" >&2
  exit 1
fi
APP="build/SpatialPreviewBridge.app"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The icon is an Icon Composer document, the only form macOS 26+ renders without
# forcing it into a grey squircle. actool turns it into the Assets.car the system
# reads, an .icns for anything older, and the two Info.plist keys below. Absolute
# paths: actool resolves a relative output against its own idea of the project root.
xcrun actool "$PWD/BlenderSpatialPreview.icon" \
  --app-icon BlenderSpatialPreview \
  --compile "$PWD/$APP/Contents/Resources" \
  --output-partial-info-plist "$PWD/build/icon.plist" \
  --platform macosx --minimum-deployment-target 27.0 \
  --target-device mac > /dev/null

xcrun swiftc -O \
  -sdk "$SDK" -target arm64-apple-macos27.0 \
  -framework SpatialPreview -framework USDKit \
  Sources/BridgeListener.swift Sources/BridgeModel.swift Sources/BridgeAppMain.swift \
  -o "$APP/Contents/MacOS/SpatialPreviewBridge"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>SpatialPreviewBridge</string>
  <key>CFBundleIdentifier</key><string>dev.adrian.spatialpreviewbridge</string>
  <key>CFBundleIconFile</key><string>BlenderSpatialPreview</string>
  <key>CFBundleIconName</key><string>BlenderSpatialPreview</string>
  <key>CFBundleName</key><string>Spatial Preview Bridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Finds your Vision Pro to preview the scene.</string>
</dict></plist>
PLIST

codesign -s - --force --timestamp=none "$APP"
echo "built: $APP"

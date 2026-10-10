#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
minimum_version=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
# Preserve the deployment target while linking against the installed SDK's UI behavior.
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_version" -Xlinker "$sdk_version"
bin_dir=$(swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_version" -Xlinker "$sdk_version" --show-bin-path)
bundle=".build/VoiceInput.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin_dir/VoiceInput" "$bundle/Contents/MacOS/VoiceInput"
cp Info.plist "$bundle/Contents/Info.plist"
resource_bundle="$bin_dir/VoiceInput_VoiceInput.bundle"
if [ -d "$resource_bundle" ]; then /usr/bin/ditto "$resource_bundle" "$bundle/Contents/Resources/VoiceInput_VoiceInput.bundle"; fi
cp LICENSE "$bundle/Contents/Resources/LICENSE"
cp README_CN.md "$bundle/Contents/Resources/使用说明.md"
codesign --force --sign - --identifier com.yetone.VoiceInput "$bundle"
codesign --verify --deep --strict "$bundle"
echo "构建完成：$bundle"

#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
destination="/Applications/VoiceInput.app"
if [ -e "$destination" ]; then
    echo "目标应用已存在，请退出并保留旧版本后再安装。" >&2
    exit 1
fi
/usr/bin/ditto .build/VoiceInput.app "$destination"
codesign --verify --deep --strict "$destination"
echo "安装完成：$destination"

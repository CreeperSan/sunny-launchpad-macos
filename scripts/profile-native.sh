#!/bin/zsh
# 在隔离数据下录制原生动画；原始 trace 留在 .build，不进入 Git。
set -euo pipefail
cd "$(dirname "$0")/.."
profile_data="${1:-$PWD/.build/profile-data}"
trace_path="$PWD/.build/native-$(date +%Y%m%d-%H%M%S).trace"
mkdir -p "$profile_data"
scripts/build-app.sh release
# 独立 bundle 身份，避免误连正在运行的正式实例；布局仍只使用指定的隔离数据。
profile_app="$PWD/.build/Sunny Native Profile.app"
ditto "$PWD/build/Sunny Launchpad.app" "$profile_app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.creepersan.SunnyLaunchpad.Profile" "$profile_app/Contents/Info.plist"
codesign --force --deep --sign - "$profile_app"
xcrun xctrace record --template 'Animation Hitches' --time-limit 14s --output "$trace_path" --env "SUNNY_DATA_DIR=$profile_data" --target-stdout "$profile_data/animation-diagnostics.log" --launch -- "$profile_app/Contents/MacOS/SunnyLaunchpad" --performance-check --quit-after-performance-check
echo "$trace_path"

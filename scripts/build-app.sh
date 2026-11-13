#!/bin/zsh
# 构建自包含 .app；本地 ad-hoc 签名仅供开发验证，发布需 Developer ID 与公证。
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --cache-path .build/cache -c "$configuration"
bin_dir="$(swift build --disable-sandbox --cache-path .build/cache -c "$configuration" --show-bin-path)"
app_dir="$PWD/build/Sunny Launchpad.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/SunnyLaunchpad" "$app_dir/Contents/MacOS/SunnyLaunchpad"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
# 兼容 SwiftPM 的原生构建与 Xcode 构建后端资源布局。
for resource in "$bin_dir"/*.bundle(N); do
    ditto "$resource" "$app_dir/Contents/Resources/$(basename "$resource")"
done
swift scripts/generate-icon.swift "$PWD/.build/AppIcon.iconset"
python3 scripts/pack-icon.py .build/AppIcon.iconset "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"

#!/bin/zsh
# 将所有可写编译缓存放在工程内，便于受限环境复现验证。
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift test --disable-sandbox --cache-path .build/cache

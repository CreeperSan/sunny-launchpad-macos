# Sunny Launchpad

macOS 26+ 原生启动器，找回旧版 Launchpad 的分页网格与文件夹整理体验。当前版本为 **0.4.0 开发预览**。

## 已实现

- AppKit 原生界面与 Core Animation 分页、文件夹展开、搜索和布局持久化。
- 首屏骨架、名称先显示、图标后台解码与淡入；内存及磁盘缓存、目录变化监听与每小时按需静默刷新。
- 旧 Launchpad 布局只读导入：先预览，确认后保存到 Sunny 自有目录。
- 独立设置窗口，经典启动台 / Liquid Glass 可切换。
- 跟随系统 / 深色 / 亮色主题。
- 跟随系统、简体中文、简体粤语、繁体中文、繁体广东话、英语、日语、韩语。
- 显示器安全区域与尺寸适配，目录刷新、备份导出与恢复。

个性化选项见「设置 → 交互与布局」：翻页及开关动画、时长、反向翻页、图标／间距百分比、行列、分页器和系统栏覆盖；外观页可调整背景模糊程度。运行模式从 Command + Tab 隐藏，可将 app 固定到 Dock。

## 构建运行

需要支持 Swift 6.2+ 和 macOS 26 SDK 的 Xcode。无需下载第三方依赖。

```sh
scripts/test.sh
scripts/build-app.sh
open "build/Sunny Launchpad.app"
```

构建默认使用 Release，也可显式执行 `scripts/build-app.sh release`。脚本只进行本地 ad-hoc 签名，正式分发仍需签名与公证。

项目使用 Swift Package 管理，没有独立的 `.xcodeproj`。在 Xcode 中选择「File → Open」，打开项目根目录的 `Package.swift`，即可浏览、编辑代码，选择 `SunnyLaunchpad` 运行或执行测试。构建独立的 `.app` 时使用上面的打包脚本；Xcode 直接运行用于开发调试。

## 使用

- 从 Dock 或菜单栏打开；Command + 逗号打开独立设置。
- 直接输入搜索，Return 启动；Esc 逐层清除搜索、关闭文件夹或收起窗口。
- 点击页码、水平滚动、Command + 左右箭头翻页。
- 图标中心拖放成组、边缘排序；右键菜单可跨页移动。拖拽手感仍处于预览验证阶段。
- 「设置 → 布局与导入」查找旧布局或手选数据库，检查预览后应用。
- 固定快捷键 Control + Option + Space，可在通用设置关闭；真实键盘兼容性仍需验收。
- 「设置 → 交互与布局」可独立控制顶部菜单栏和 Dock 的覆盖；使用窗口覆盖，不切换系统 Dock 隐藏状态。
- 同页「实验性 → 使用系统能力优化动画」默认关闭，手动开启后使用私有系统能力增强菜单栏过渡；不可用时回退普通窗口动画。

默认自有数据位于 `~/Library/Application Support/com.creepersan.SunnyLaunchpad/`；`workspace.json` 保存状态及目录更新时间，`IconCache` 保存可重建的图标缓存，`Backups` 保留最近 30 份变更前备份。相同状态不重复备份。不会改写 Dock 数据、重置系统启动台或移动实际应用包。

开发隔离运行：

```sh
SUNNY_DATA_DIR="$PWD/.build/dev-data" "build/Sunny Launchpad.app/Contents/MacOS/SunnyLaunchpad"
```

## 文档与边界

[文档索引](doc/README.md)包含调研来源、需求、功能模块、技术分层、任务拆解和实际验证记录。多屏热插拔、macOS 26 真机、完整拖放、可访问性和签名发布仍在任务清单中。

架构为 `SunnyLaunchpad → SunnyPresentation / SunnyInfrastructure → SunnyDomain`。领域层仅依赖 Foundation；UI 不直接访问旧库或文件仓储。旧数据库格式并非 Apple 公共接口，仅对已验证结构提供解析，遇到未知结构明确报错。

MIT License · CreeperSan

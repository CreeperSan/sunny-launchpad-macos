# Sunny Launchpad

macOS 26+ 原生启动器，找回旧版 Launchpad 的分页网格与文件夹整理体验。当前版本为 **0.1.0 开发预览**。

## 已实现

- 应用扫描、分页、搜索、启动、文件夹和布局持久化。
- 旧 Launchpad 布局只读导入：先预览，确认后保存到 Sunny 自有目录。
- 独立设置窗口，经典启动台 / Liquid Glass 可切换。
- 跟随系统 / 深色 / 亮色主题。
- 跟随系统、简体中文、简体粤语、繁体中文、繁体广东话、英语、日语、韩语。
- 显示器安全区域与尺寸适配，目录刷新、备份导出与恢复。

## 构建运行

需要支持 Swift 6.2+ 和 macOS 26 SDK 的 Xcode。无需下载第三方依赖。

```sh
scripts/test.sh
scripts/build-app.sh
open "build/Sunny Launchpad.app"
```

发布配置可使用 `scripts/build-app.sh release`。脚本只进行本地 ad-hoc 签名，正式分发仍需签名与公证。Xcode 可直接打开 `Package.swift`。

## 使用

- 从 Dock 或菜单栏打开；Command + 逗号打开独立设置。
- 直接输入搜索，Return 启动；Esc 逐层清除搜索、关闭文件夹或收起窗口。
- 点击页码、水平滚动、Command + 左右箭头翻页。
- 图标中心拖放成组、边缘排序；右键菜单可跨页移动。拖拽手感仍处于预览验证阶段。
- 「设置 → 布局与导入」查找旧布局或手选数据库，检查预览后应用。
- 固定快捷键 Control + Option + Space，可在通用设置关闭；真实键盘兼容性仍需验收。

默认自有数据位于 `~/Library/Application Support/com.creepersan.SunnyLaunchpad/`；`workspace.json` 保存状态，`Backups` 保留最近 30 份变更前备份。相同状态不重复备份。不会改写 Dock 数据、重置系统启动台或移动实际应用包。

开发隔离运行：

```sh
SUNNY_DATA_DIR="$PWD/.build/dev-data" "build/Sunny Launchpad.app/Contents/MacOS/SunnyLaunchpad"
```

## 文档与边界

[文档索引](doc/README.md)包含调研来源、需求、功能模块、技术分层、任务拆解和实际验证记录。多屏热插拔、macOS 26 真机、完整拖放、可访问性和签名发布仍在任务清单中。

架构为 `SunnyLaunchpad → SunnyPresentation / SunnyInfrastructure → SunnyDomain`。领域层仅依赖 Foundation；UI 不直接访问旧库或文件仓储。旧数据库格式并非 Apple 公共接口，仅对已验证结构提供解析，遇到未知结构明确报错。

MIT License · CreeperSan

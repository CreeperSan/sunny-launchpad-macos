# LaunchOS 显隐与 Dock 调研

调研日期：2026-11-14。以下为首轮调查记录；后续实现与验证见文末。

## 结论

Sunny 的 Dock 先消失、内容后入场，以及内容先退场、Dock 后出现，都有明确的代码原因：显示空窗口后先设置系统 presentationOptions，再异步挂载内容；退出动画等待结束后才恢复 presentationOptions。

本机 LaunchOS 的实现有实质差异：全屏展示分支根据 hideDock 偏好选择窗口层级，用窗口盖住 Dock；菜单栏另有透明度控制；图层初态在窗口入场之前准备。可以参考这种结构，优先移除 Sunny 显隐过程中对 Dock 状态的切换。

这不是已完成的端到端性能测量。不能据此断言 LaunchOS 在所有环境都无卡顿，也不能声称 Sunny 的全部延迟都由 Dock 引起。

## 调查对象与证据边界

- 本机 `/Applications/LaunchOS.app`，版本 2.5.0，build 519，bundle ID `app.remixdesign.LaunchOS`。
- 主程序 SHA-256：`c65a2d2da35b8b96bdc3a896ec6eb92363698a70ba3cf7f6452bf0e7b7df6aee`。
- 静态分析使用 Universal Mach-O 的 arm64 部分；下文地址为未加 ASLR slide 的虚拟地址。
- 使用 Info.plist、导入符号、Objective-C / Swift 类元数据、反汇编调用与参数交叉核对；没有 LaunchOS 的完整源码。
- 查阅官方介绍及版本记录；用本机界面截图确认全屏最终状态。截图不能证明过渡时序和帧率。
- 未修改 LaunchOS 应用包、偏好或 Dock 配置，未向运行进程注入代码。
- Sunny 检查基于当前工作区，Git HEAD 为 `afc7381`。

官方确认其采用 Swift + AppKit；但 Sunny 也已经是 AppKit，因此框架名称本身不能解释差异。[LaunchOS 官方介绍](https://launchosapp.com/blog/en/introducing-launchos/)

## LaunchOS：能直接证实的实现

### 1. hideDock 偏好控制窗口层级

`LaunchpadWindowController` 的 `0x1000433dc` 函数读取 displayMode 和 hideDock：

| 分支 | 传给 setLevel: 的值 |
| --- | --- |
| displayMode 非零分支 | 3 |
| displayMode 为零，hideDock 为 false | 19 |
| displayMode 为零，hideDock 为 true | 1000 |

关键核对点：

- 元数据中的 `0x10042a1f8` 对应 `_displayMode`，`0x10042a200` 对应 `_hideDock`。
- `0x100043450` 开始读取 `_hideDock`；`0x100043484`～`0x10004348c` 按布尔值选择 19 / 1000。
- `0x100043494` 调用 `setLevel:`。Objective-C 消息桩地址为 `0x1003549a0`。
- 当前 SDK 的 `CGWindowLevel.h` 定义 Dock 层级为 20、菜单栏为 24、屏保层级为 1000。因此 19 位于 Dock 以下，1000 位于其上。

可以证实的是参数与分支。结合偏好名称、窗口控制器和 SDK 层级，判断这是“保留 Dock 在窗口上方 / 窗口覆盖 Dock”的切换。它不需要触发 Dock 本身的隐藏和恢复。

未在本次静态检查中找到 `setPresentationOptions:` 消息，也未找到 Sunny 当前这组 hideDock + hideMenuBar 设置。未发现不能扩大为“整个程序任何路径都绝不动态调用”。

### 2. 菜单栏单独做透明度过渡

存在明确的私有函数调用：

- `CGSMainConnectionID`
- `CGSSetMenuBarInsetAndAlpha`

`0x100047904` 的函数会取消已有菜单栏 timer，将透明度约束在 0～1，按时长和差值选择直接更新或定时过渡；`0x100047b84`、`0x100048060` 等位置调用上述透明度函数。

类元数据还包含 `menuBarTimer`、`lastMenuBarAlpha`。因此菜单栏过渡并非只依赖高层级窗口遮挡。

这是 LaunchOS 与 Sunny 的另一处差异，但该函数不是公开 AppKit API。不能为了复现视觉效果就无条件照搬；系统升级兼容和异常退出后的恢复，都需要额外验证。

### 3. 入场前准备图层初态，并从当前呈现值继续动画

全屏动画路径中可见：

- `0x100045fd4` 附近读取 opacity；周边路径读取 presentationLayer，以取得正在呈现的状态。
- `0x1000460f4`～`0x100046138` 使用 CATransaction、关闭隐式动画、设置初始透明度和变换，再提交。
- `0x100046144`～`0x100046150` 随后设置窗口 alpha 并 `makeKeyAndOrderFront:`。
- `0x100046668`、`0x1000466ec` 添加显式 CAAnimation。

元数据还保留 `backgroundVC`、`launchpadVC`、惰性 `windowSurfaceView`，以及 `fadeState`、`fadeGeneration`、`presentationRequestID`、`pendingHideCompletions`。

这些证据支持“保留界面对象、准备好初态再入场、用状态与代次过滤过期完成回调”的设计。不能仅凭成员名证明所有展示路径都没有重建和同步工作。

### 4. 动画时长并没有明显比 Sunny 更短

初始化代码 `0x10004d380`～`0x10004d398` 将 `animationDuration` 设为 0.24 秒；`hiddenScale` 初始化为 1.05。Sunny 当前默认入场时长是 0.25 秒，内容初始放大为 1.14。

这说明“少 10ms”不足以解释体验差距；初始缩放幅度和时序更值得比较。这里只确认初始化默认值，不把它当作所有模式下的实际执行时长。

### 5. 有私有 Dock 符号，但不能误认它们负责显隐

导入 `CoreDockGetAutoHideEnabled`、`CoreDockGetOrientationAndPinning`、`CoreDockGetRect`，调用位置集中在屏幕 / Dock 信息读取路径。

同时存在 `CoreDockSendNotification`。本次找到的调用点 `0x100124594` 传入的是 `com.apple.showdesktop.set` 或 `com.apple.showdesktop.awake`，存在 macOS 版本分支。不能把它解释成“通过这个函数隐藏 Dock”。

## Sunny：当前问题如何发生

| 环节 | 当前实现 | 对体验的影响 |
| --- | --- | --- |
| 打开 | AppDelegate.swift:103 每次把 contentView 换成空 NSView | 热启动也会先卸载已有视图，失去原本可直接显示的完整画面 |
| 首次提交 | :106～109 显示空窗口、display、flush，再应用 presentation | 系统栏切换与内容入场拆成不同提交阶段 |
| Dock 隐藏 | :150 设置 `[.hideDock, .hideMenuBar]` | 主动改变系统 Dock 状态；Apple 定义 hideDock 为完全隐藏并禁用 Dock |
| 内容入场 | :112～121 经 Task.yield 后 configure、布局、播放动画 | 系统栏先变，内容尚未开始；Task.yield 不保证下一帧固定开始 |
| 数据准备 | :111 在入场任务之前安排 prepare | 两者都可能占用主线程，不能把这一段当成隔离于入场的后台工作 |
| 关闭 | :138 等待动画时长；:140～141 隐藏窗口并恢复 presentation | 内容渐淡时 Dock 仍被禁用，最后才恢复，天然形成第二段动作 |
| 连续切换 | :161 仅依据 isVisible 判断开或关 | 正在关闭时再次按快捷键仍走 hide；被 closing guard 忽略，无法立即反向打开 |

`NativeLauncherView.swift:320` 开始会给整个根图层做 opacity 动画，内容另做缩放。这本来足以让下面的 Dock 随窗口淡入淡出自然被遮住 / 露出；系统额外 hideDock 反而让两条路径互相错开。

Apple 的公开定义见 [hideDock](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct/hidedock)。菜单栏隐藏选项必须搭配 Dock 隐藏，是 presentationOptions 的约束，见 [PresentationOptions](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct)。

## 可参考的修改方案

建议先实施只用公开 API 的最小修复，再做对照验收：

1. 显隐路径停止设置 hideDock / hideMenuBar。保留“覆盖菜单栏和 Dock”的现有偏好语义，通过窗口层级和覆盖范围实现；不改系统 Dock 用户设置。
2. 保留窗口和已有 contentView。隐藏时只 orderOut；再次显示时不先换成空视图。显示器、尺寸或外观参数变化才重新配置。
3. 隐藏状态下挂载内容、完成布局、设置入场起点，然后在同一次显示流程中提交显式动画。删除空窗口 flush 与入场 Task.yield 的分段。
4. 关闭时让根图层淡出直接露出下面的 Dock；动画完成只收起窗口，无需再恢复 Dock。
5. 显隐可反向：正在关闭时收到打开指令，从 presentation layer 的当前值继续；用代次或取消机制避免旧关闭回调把新打开的窗口收掉。不要用固定 sleep 作为唯一的动画完成信号。
6. 首次扫描、图标与壁纸准备继续异步；单独测冷启动，不能为了热启动优化让冷启动等待全目录或整张壁纸完成。

覆盖系统栏所用层级应命名并集中管理。LaunchOS 的 1000 是调查结果，不代表 Sunny 必须原样采用：Sunny 当前 mainMenu + 1 已高于常规 Dock；需要先验证这个较低层级是否足够，再决定是否提高。过高层级可能遮住输入法候选、菜单、设置和其他辅助窗口。

菜单栏优先由窗口覆盖完成。私有透明度 API 留作独立评估；它不是解决 Dock 两段式切换的必要条件。

## 验证方法与未决问题

本轮没有改运行代码，未运行构建或测试，也没有新的 120 FPS / 端到端毫秒结果。

后续验收需要分别记录“输入到首个有效画面”“过渡耗时”“实际呈现的长帧”，而不是只看 displayLink 回调频率：

- 冷启动、首次无缓存、常驻后重复显隐分别采样。
- Dock 常显 / 自动隐藏，底部 / 左 / 右，覆盖偏好开 / 关。
- 多显示器、全屏应用所在 Space、Stage Manager、屏幕切换。
- 动画中连续打开关闭、点击应用跳转、打开设置、切出应用。
- 减少动态效果、减少透明度，以及中文输入法候选窗口层级。
- 同屏条件下对照 LaunchOS，检查 Dock 是否随根层透明度连续露出，是否仍有独立滑入或空白帧。

官方版本记录也多次修复窗口、手势、壁纸和多屏问题。因此参考其思路合理，但不能把单机观察外推为它在所有环境绝无问题。[LaunchOS 官方版本记录](https://launchosapp.com/release.en)

## 复查命令

以下均为只读检查，输出建议留在临时目录，不将完整第三方反汇编纳入项目：

```sh
plutil -p /Applications/LaunchOS.app/Contents/Info.plist
shasum -a 256 /Applications/LaunchOS.app/Contents/MacOS/LaunchOS
nm /Applications/LaunchOS.app/Contents/MacOS/LaunchOS
otool -arch arm64 -ov /Applications/LaunchOS.app/Contents/MacOS/LaunchOS
otool -arch arm64 -tvV /Applications/LaunchOS.app/Contents/MacOS/LaunchOS
otool -arch arm64 -v -s __TEXT __objc_stubs /Applications/LaunchOS.app/Contents/MacOS/LaunchOS
otool -arch arm64 -v -s __DATA __objc_selrefs /Applications/LaunchOS.app/Contents/MacOS/LaunchOS
```

注意此程序有 chained fixups，otool 的 selref 输出不能直接当普通绝对字符串地址使用；本次交叉解析消息桩和 selector，才确定了 setLevel、makeKeyAndOrderFront 和 addAnimation 等实际调用。


## 后续实现（2026-11-14）

根据用户确认，已实施显隐调整，并使用三个全新的配置项，不迁移旧合并开关：

- `coverMenuBar`：覆盖顶部菜单栏，默认开启。
- `coverDock`：覆盖 Dock，默认开启。
- `useSystemAnimation`：设置 → 交互与布局 → 实验性 →「使用系统能力优化动画」，默认关闭，只能手动开启。

普通路径不再设置 NSApp.presentationOptions，也不改 Dock 偏好。窗口矩形分别预留未覆盖的顶部菜单栏和 Dock 区域；覆盖时使用 mainMenu + 1 的常规层级。左／右 Dock 不覆盖时窗口保留该侧窄条，包括其顶部角落；这仍是单矩形窗口的边界，未宣称多显示器和所有 Dock 位置均完成视觉验收。

窗口及内容保留复用，自有布局与偏好先读取再准备首帧，不等待全目录扫描。移除显示空窗口、flush、Task.yield 后才安装内容的过程。退出由 Core Animation 完成回调收起窗口，代次校验防止过期退出回调隐藏新打开的窗口；反向打开从当前呈现值继续。

实验功能动态解析 SkyLight 的 CGSMainConnectionID 和 CGSSetMenuBarInsetAndAlpha，仅在实验开关开启且覆盖顶部菜单栏时调用。按显示链回调和实际经过时间线性更新菜单栏透明度，符合本次观察到的 LaunchOS 路径。退出、切出应用、关闭实验选项或关闭顶部覆盖时恢复透明度。缺少符号或调用返回错误时记录日志并回退到普通窗口覆盖。该能力仍是私有 API，系统版本变更造成的 ABI 或行为变化不能靠符号存在性检测完全防范。

ABI 交叉核对来源：[yabai 的 SkyLight 接口声明](https://github.com/asmvik/yabai/blob/master/src/misc/extern.h)，声明为连接 ID、两个 double 参数与 float 透明度，返回 CGError；调用时两个 double 参数沿用观察到的 0 和 1。

隔离版启动验证曾触发 AppKit 外观断言。系统日志明确记录在外观资源加载前已出现 Too many open files；原目录监听为每个分类子目录持有描述符。现改为 FSEvents 递归事件流，去除启动遍历和逐目录描述符，也无需在每次目录变化后重新注册。

验证记录：

- 52 项测试在本机正常执行环境通过（Presentation 35、Infrastructure 6、Domain 11），包括四种覆盖组合、侧边 Dock 与壁纸定位、新配置往返、实验默认关闭、动画反向及新分类目录的递归监听／停止。
- AppKit 用例使用串行套件，避免异步等待期间共享 NSApplication 的操作交错；设置导航测试改用实际提供的辅助功能名称。
- 受限测试进程收不到 FSEvents 系统事件，新增监听集成测试需在正常本机环境执行；其余 51 项在受限环境通过。
- 隔离 bundle 和隔离数据中已通过 CUA 启动应用，核对设置排版、两个覆盖复选框及实验默认关闭；手动开启实验选项后能打开并关闭启动器，随后恢复实验关闭并退出隔离实例。独立保存结果为菜单栏开启、Dock 关闭、实验关闭；未修改正式用户配置。
- 未重新量化首帧毫秒延迟或实际 GPU 呈现帧率，不将界面烟测作为持续满 120 FPS 的证据。多屏、输入法层级和不同系统版本仍需验收。

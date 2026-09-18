# HeadPrivacy

HeadPrivacy 是一款原生 macOS 菜单栏隐私辅助工具。它读取支持头部追踪的 AirPods 的水平转头（yaw），判断你正在看哪一台已校准显示器：正在看的显示器保持清晰，其余显示器自动显示隐私遮罩；当朝向落在所有已校准区域之外时，所有显示器都会被保护。

> HeadPrivacy 不是 macOS 锁屏的替代品，也不提供硬安全保证。

## 系统要求

- Apple-silicon MacBook（M 系列），macOS 14 或更高版本；使用时必须保持 MacBook 内置显示器启用。可以连接零台或多台外接显示器，但所有活动显示器必须水平排列。不支持 Mac mini、Mac Studio 或仅外接显示器的布局。
- 能通过 Core Motion 提供 headphone motion 的 AirPods。验收目标为普通 AirPods 第 3 代或更新型号，以及 AirPods Pro；最终以运行时 `isDeviceMotionAvailable` 能力检查为准，不能据此推断所有 AirPods 代际都支持。
- Xcode / Swift 构建工具。

首版只支持包含 MacBook 内置显示器的水平排列，不支持上下堆叠、重叠或仅外接显示器的布局。

## 构建与启动

在仓库根目录运行：

```bash
./Scripts/build-app.sh
open build/HeadPrivacy.app
```

脚本会生成 arm64 Release bundle：`build/HeadPrivacy.app`，并进行本地 ad-hoc 签名。它没有经过 notarization，也不是 App Store 分发版本；macOS 可能要求你确认本地应用的首次打开。

## 首次使用与每次启动

1. 连接并佩戴支持的 AirPods，启动 HeadPrivacy。
2. 在 macOS 提示时允许 Motion & Fitness（运动与健身）权限。
3. 按引导从左到右校准：第一台显示器在按下“Begin”后采样；之后每切换到一台新显示器，先转头看向高亮中心，再按“I'm Looking Here — Start Sampling”，然后保持稳定约一秒。
4. 完成每个中心的采样后，按引导验证显示器选择，再开启自动保护。

每次启动都必须重新完成引导校准。AirPods 提供的是相对于本次 motion 会话的头部姿态参考；进程重启后不能安全恢复同一物理参考，因此 app 不会直接复用旧角度。每台显示器已保存的区域宽度会在本次重新验证后继续使用。

校准完成后，只有当前朝向对应的显示器保持清晰。大幅转头、朝向所有显示器区域之外时，全部显示器都会被保护。这里判断的是水平头部朝向，不是眼球注视点。

## 模式与设置

默认配置为：

- `Side`：只保护显示器两侧区域；也可选择整屏 `Full-screen`。
- `Translucent` 半透明外观；另有 `Soft` 和更强的 `Privacy`。
- `Usability-first`：耳机断开、权限不可用或 motion 样本中断时移除遮罩；可改为 `Protection-first`，中断时保护所有显示器。
- 全局暂停/恢复快捷键：`⌃⌥⌘P`。

Settings 中可以调整触发区域宽度、切换/离开/返回停留时间、平滑强度、遮罩透明度和亮度、Side 宽度、每台显示器的区域宽度、失败策略、通知、登录时启动和全局快捷键。当前 motion 参考和完整显示器拓扑仍然有效时，可以只重校准某一台显示器；启动、唤醒、耳机断开或显示器布局变化后必须执行完整校准。

`Protection-first` 因 motion 中断或校准失效而覆盖显示器时，遮罩会显示不含屏幕内容的状态说明。此时仍可从菜单选择暂停/临时显示全部，或按已配置的全局快捷键立即显示全部；在安全校准恢复前不能重新开启自动保护。

通知授权不会因启动 app 或仅打开通知开关而自动请求。只有在 Settings 中主动按下通知授权按钮时，HeadPrivacy 才会请求系统通知权限。

## 隐私设计

- 只请求 Motion 权限；不需要 Screen Recording、Accessibility、相机、麦克风、定位或网络权限。
- 不截取、读取或存储屏幕像素，也不包含遥测或网络连接。
- 原始 motion 样本只在内存中参与即时分类，随后丢弃，不写入磁盘。
- 持久化校准只包含显示器 ID、显示器名称、相对中心 yaw 和区域半宽；不保存屏幕 frame、拓扑几何或 motion 历史。

## 已知限制与验收状态

- 这是基于 yaw 的头部朝向估计，不是眼动追踪；只转动眼睛不会改变选择。
- 上下堆叠的显示器布局不受支持。
- App 退出或崩溃时，其 overlay 窗口会被 macOS 移除，保护随之消失。
- 它不能替代锁定 Mac；离席或处理高敏感内容时仍应使用系统锁屏。
- 当前构建是本地 ad-hoc 签名版本，未 notarize、未通过 App Store 分发。
- 自动化测试和 bundle 静态检查不等于真实硬件验收。普通 AirPods、AirPods Pro、多显示器、Spaces、权限 UI 与实测延迟仍须由用户在真实设备上执行并记录。

完整步骤和待完成项目见[手动验收清单](docs/manual-test-checklist.md)。

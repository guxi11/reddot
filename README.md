Project: macOS Red Dot Focus & Vim Mode

## 项目愿景

一个 macOS 效率工具，自动监控应用红点（Badge），在红点出现时自动切换应用至前台，并进入“Vim Normal 模式”，允许通过键盘快捷键快速点击红点位置（f）、滚动点击红点后的可滚动区域、进入编辑模式、使用esc退出编辑模式到normal模式、使用esc退出normal模式。

## 核心功能

1. 红点监控 (Red Dot Monitor)
- 监听 Dock 图标或应用窗口内的红点/Badge 变化。
- 触发条件：检测到新的红点出现。
2. 自动切换 (Auto-Switch)
- 当红点出现时，自动将对应 App 激活并置于前台。
3. Vim 导航模式 (Vim-like Normal Mode)
- App 切换后自动进入“普通模式”。
- 拦截全局键盘事件，禁用默认输入。
- 使用 f 快捷键，支持点击红点。
- 使用jk滚动屏幕。

## 技术架构方案

1. 红点/Badge 检测层

- 首选方案 (Accessibility API):
- 原理: 通过 AXUIElement 访问 Dock 进程 (com.apple.dock) 的子元素。
- 实现: 遍历 Dock item，读取 AXValue 或特定属性判断是否有 Badge 文本。
- 优点: 性能高，系统级数据，准确。
- 参考: https://github.com/xiaogdgenuine/Doll (开源 macOS Badge 监控工具)。
- 限制: 需要轮询 (Polling)，建议频率 1秒/次。
- 备选方案 (ScreenCaptureKit):
- 原理: 实时录屏分析像素。
- 实现: 使用 Vision Framework 或 Core Image 检测红色圆形区域。
- 缺点: 耗电较高，需要录屏权限。

2. 窗口管理与切换

- API: NSRunningApplication
- 代码:
if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
    app.activate(options: [.activateIgnoringOtherApps])
}

3. 输入拦截与模拟 (Vim Mode)

- 键盘拦截: Quartz Event Services (CGEventTap)
- 创建一个全局 Event Tap 拦截 keyDown / keyUp 事件。
- 在 Vim 模式下吞掉按键事件，执行内部逻辑。
- 模拟点击: CGEvent
- 创建 kCGEventLeftMouseDown 和 kCGEventLeftMouseUp 事件并 post 到系统。

## 权限要求 (Permissions)

- Accessibility (辅助功能): 必须。用于读取 Dock Badge、拦截键盘、模拟点击。
- Screen Recording (屏幕录制): 可选。仅在使用视觉识别红点方案时需要。

## 推荐开发路线

1. 原型阶段: 实现读取 Dock Badge 数值 (参考 Doll)。
2. 控制阶段: 实现检测到数值变化后调用 activate() 切换窗口。
3. 交互阶段: 实现 CGEventTap 拦截键盘，按 Esc 退出模式，按特定键模拟点击屏幕中心。


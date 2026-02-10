//
//  ModeIndicatorWindow.swift
//  Reddot
//
//  浮动 HUD 窗口，短暂显示当前 Vim 模式文字（NORMAL / INSERT / EXIT）
//

import AppKit

class ModeIndicatorWindow {
    private static var window: NSWindow?
    private static var hideTimer: Timer?

    static func show(text: String) {
        hideTimer?.invalidate()

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let padding: CGFloat = 24
        let windowSize = NSSize(width: label.frame.width + padding * 2, height: label.frame.height + padding)

        // 定位到屏幕底部居中
        guard let screen = NSScreen.main else { return }
        let origin = NSPoint(
            x: screen.frame.midX - windowSize.width / 2,
            y: screen.frame.minY + 120
        )

        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(origin: origin, size: windowSize),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            w.level = .floating
            w.isOpaque = false
            w.backgroundColor = NSColor.black.withAlphaComponent(0.75)
            w.hasShadow = true
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary]

            // 圆角
            w.contentView?.wantsLayer = true
            w.contentView?.layer?.cornerRadius = 10
            w.contentView?.layer?.masksToBounds = true

            window = w
        }

        let w = window!
        w.setFrame(NSRect(origin: origin, size: windowSize), display: true)

        label.frame = NSRect(x: padding, y: padding / 2, width: label.frame.width, height: label.frame.height)
        w.contentView?.subviews.forEach { $0.removeFromSuperview() }
        w.contentView?.addSubview(label)

        w.alphaValue = 1.0
        w.orderFrontRegardless()

        // 自动隐藏
        let duration: TimeInterval = text == "EXIT" ? 0.8 : 2.0
        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                w.animator().alphaValue = 0
            }, completionHandler: {
                w.orderOut(nil)
            })
        }
    }
}

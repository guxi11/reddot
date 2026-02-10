//
//  HintOverlayWindow.swift
//  Reddot
//
//  Vimium 风格浮动标签：在每个红点位置显示黄底黑字字母标签
//

import AppKit

class HintOverlayWindow {
    private static var windows: [NSWindow] = []

    /// 显示 hints，每个 hint 是一个独立的小窗口贴在红点旁边
    static func show(hints: [(label: String, position: CGPoint)]) {
        dismiss()

        for hint in hints {
            let label = NSTextField(labelWithString: hint.label)
            label.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
            label.textColor = .black
            label.alignment = .center
            label.sizeToFit()

            let paddingH: CGFloat = 6
            let paddingV: CGFloat = 2
            let tagSize = NSSize(
                width: label.frame.width + paddingH * 2,
                height: label.frame.height + paddingV * 2
            )

            // hint.position 是屏幕坐标（左上角原点），NSWindow 使用左下角原点
            // 将标签放在红点左上角偏移位置
            guard let screen = NSScreen.main else { continue }
            let flippedY = screen.frame.height - hint.position.y - tagSize.height
            let origin = NSPoint(
                x: hint.position.x - tagSize.width - 2,
                y: flippedY
            )

            let w = NSWindow(
                contentRect: NSRect(origin: origin, size: tagSize),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = NSColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 0.95) // Vimium 黄
            w.hasShadow = true
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary]

            w.contentView?.wantsLayer = true
            w.contentView?.layer?.cornerRadius = 3
            w.contentView?.layer?.masksToBounds = true
            w.contentView?.layer?.borderWidth = 1
            w.contentView?.layer?.borderColor = NSColor.black.withAlphaComponent(0.3).cgColor

            label.frame = NSRect(x: paddingH, y: paddingV, width: label.frame.width, height: label.frame.height)
            w.contentView?.addSubview(label)

            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    static func dismiss() {
        for w in windows {
            w.orderOut(nil)
        }
        windows.removeAll()
    }
}

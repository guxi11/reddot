//
//  VimModeController.swift
//  Reddot
//
//  全局监听 Control+f 进入 hint 模式，显示 Vimium 风格字母标签，
//  按对应字母点击红点，按 Esc 取消。
//

import AppKit
import CoreGraphics

class VimModeController {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hintActive = false
    private var pendingHints: [(label: String, position: CGPoint)] = []

    init() {}

    /// 启动全局快捷键监听（应用启动时调用一次）
    func start() {
        installEventTap()
    }

    func stop() {
        exitHintMode()
        removeEventTap()
    }

    // MARK: - Event Tap

    private func installEventTap() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
                let controller = Unmanaged<VimModeController>.fromOpaque(userInfo).takeUnretainedValue()
                return controller.handleKeyEvent(type: type, event: event)
            },
            userInfo: selfPtr
        )

        guard let tap = eventTap else {
            print("[Reddot] Failed to create CGEventTap.")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
    }

    // MARK: - Key Handling

    private func handleKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 重新启用被系统超时禁用的 tap
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if hintActive {
            // hint 模式下：Esc 取消，字母键选择
            if keyCode == 53 { // Esc
                exitHintMode()
                return nil
            }
            if let char = KeyCode.letterForKeyCode(keyCode),
               let matched = pendingHints.first(where: { $0.label == char }) {
                exitHintMode()
                simulateClick(at: matched.position)
                return nil
            }
            // 吞掉其他按键
            return nil
        }

        // 非 hint 模式：只拦截 Control+f
        if keyCode == 3 && flags.contains(.maskControl) {
            enterHintMode()
            return nil
        }

        // 其他按键全部放行
        return Unmanaged.passRetained(event)
    }

    // MARK: - Hint Mode

    private func enterHintMode() {
        Task.detached { [weak self] in
            let dots = await RedDotImageDetector.detectAsync()

            await MainActor.run {
                guard let self = self else { return }
                if dots.isEmpty {
                    ModeIndicatorWindow.show(text: "NO BADGE")
                    return
                }

                let labels = "abcdefghijklmnopqrstuvwxyz"
                self.pendingHints = []
                for (i, pos) in dots.enumerated() {
                    guard i < labels.count else { break }
                    let label = String(labels[labels.index(labels.startIndex, offsetBy: i)])
                    self.pendingHints.append((label: label, position: pos))
                }

                self.hintActive = true
                print("[Reddot] Showing \(self.pendingHints.count) hints")
                HintOverlayWindow.show(hints: self.pendingHints)
            }
        }
    }

    private func exitHintMode() {
        hintActive = false
        pendingHints = []
        DispatchQueue.main.async { HintOverlayWindow.dismiss() }
    }

    // MARK: - 模拟点击

    private func simulateClick(at point: CGPoint) {
        // 先激活目标应用，确保点击事件能正确送达
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            frontApp.activate()
        }

        let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        mouseDown?.post(tap: .cghidEventTap)
        // 50ms 延迟让目标应用处理 mouseDown
        usleep(50_000)
        mouseUp?.post(tap: .cghidEventTap)
    }
}

// MARK: - Key Codes

private enum KeyCode {
    private static let keyCodeToLetter: [Int64: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
        34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o",
        35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v",
        13: "w", 7: "x", 16: "y", 6: "z"
    ]

    static func letterForKeyCode(_ code: Int64) -> String? {
        return keyCodeToLetter[code]
    }
}

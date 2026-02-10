//
//  ReddotApp.swift
//  Reddot
//
//  Created by zhangyuanyuan on 2026/2/10.
//

import SwiftUI
import ScreenCaptureKit

@main
struct ReddotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // MenuBar 常驻，无主窗口
        Settings {
            EmptyView()
        }
    }
}

/// AppDelegate 负责 MenuBar 图标、权限检查、启动核心服务
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var badgeMonitor: DockBadgeMonitor?
    private var vimModeController: VimModeController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标，纯 MenuBar 应用
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()

        // 检查辅助功能权限
        if !checkAccessibilityPermission() {
            showAccessibilityAlert()
            return
        }

        // 检查屏幕录制权限（图像识别红点需要）
        if !checkScreenRecordingPermission() {
            showScreenRecordingAlert()
        }

        startServices()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Reddot")
            button.image?.isTemplate = true // 跟随系统深色/浅色
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Monitoring...", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "请在 系统设置 > 隐私与安全性 > 辅助功能 中允许 Reddot，然后重新启动应用。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "退出")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        NSApp.terminate(nil)
    }

    /// 尝试获取可共享内容来检测屏幕录制权限
    private func checkScreenRecordingPermission() -> Bool {
        var hasPermission = false
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                hasPermission = true
            } catch {
                hasPermission = false
            }
            semaphore.signal()
        }
        semaphore.wait()
        return hasPermission
    }

    private func showScreenRecordingAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "Reddot 使用图像识别检测红点，需要屏幕录制权限。请在 系统设置 > 隐私与安全性 > 屏幕录制 中允许 Reddot。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func startServices() {
        vimModeController = VimModeController()
        vimModeController?.start()

        badgeMonitor = DockBadgeMonitor { [weak self] appName, bundleId, badgeValue in
            self?.handleBadgeDetected(appName: appName, bundleId: bundleId, badgeValue: badgeValue)
        }
        badgeMonitor?.startMonitoring()
        updateMenu(monitoring: true)
    }

    private func handleBadgeDetected(appName: String, bundleId: String, badgeValue: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func updateMenu(monitoring: Bool) {
        guard let menu = statusItem.menu, let firstItem = menu.items.first else { return }
        firstItem.title = monitoring ? "Monitoring..." : "Stopped"
    }

    @objc private func quit() {
        badgeMonitor?.stopMonitoring()
        vimModeController?.stop()
        NSApp.terminate(nil)
    }
}

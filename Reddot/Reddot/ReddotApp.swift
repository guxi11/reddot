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
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var badgeMonitor: DockBadgeMonitor?
    private var vimModeController: VimModeController?
    
    private let userDefaults = UserDefaults.standard

    // MARK: - UserDefaults Keys
    private let autoActivationDisableUntilKey = "autoActivationDisableUntil"
    private let ignoredAppsKey = "ignoredBundleIds"
    private let throttleIntervalKey = "throttleInterval"
    private let inputCooldownKey = "inputCooldown"
    private let persistentHintModeKey = "persistentHintMode"

    // MARK: - 可选档位
    private let throttleOptions: [(title: String, value: TimeInterval)] = [
        ("5 seconds", 5),
        ("10 seconds", 10),
        ("30 seconds", 30),
        ("60 seconds", 60),
    ]
    private let cooldownOptions: [(title: String, value: TimeInterval)] = [
        ("1 second", 1),
        ("3 seconds", 3),
        ("5 seconds", 5),
    ]

    // MARK: - Menu Item Tags (用于定位动态子菜单)
    private let ignoredAppsMenuTag     = 100
    private let throttleMenuTag        = 101
    private let cooldownMenuTag        = 102
    private let persistentHintModeTag  = 103

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标，纯 MenuBar 应用
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()

        // 检查辅助功能权限
        if !checkAccessibilityPermission() {
            showAccessibilityAlert()
            return
        }

        startServices()

        // 异步检查屏幕录制权限（仅打印日志，不弹窗；实际使用红点检测时再按需提示）
        Task.detached {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                print("[Reddot] Screen recording permission: granted")
            } catch {
                print("[Reddot] Screen recording permission: not granted (\(error.localizedDescription)). Red dot image detection will be unavailable.")
            }
        }
    }

    // MARK: - 从 UserDefaults 读取持久化配置

    private func loadIgnoredApps() -> Set<String> {
        let array = userDefaults.stringArray(forKey: ignoredAppsKey) ?? []
        return Set(array)
    }

    private func saveIgnoredApps(_ ids: Set<String>) {
        userDefaults.set(Array(ids), forKey: ignoredAppsKey)
    }

    private func loadThrottleInterval() -> TimeInterval {
        let val = userDefaults.double(forKey: throttleIntervalKey)
        return val > 0 ? val : 10.0 // 默认 10s
    }

    private func loadInputCooldown() -> TimeInterval {
        let val = userDefaults.double(forKey: inputCooldownKey)
        return val > 0 ? val : 3.0 // 默认 3s
    }

    // MARK: - Status Item & Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Monitoring...", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // Ignored Apps 子菜单
        let ignoredItem = NSMenuItem(title: "Ignored Apps", action: nil, keyEquivalent: "")
        ignoredItem.tag = ignoredAppsMenuTag
        ignoredItem.submenu = NSMenu() // 占位，menuNeedsUpdate 时填充
        menu.addItem(ignoredItem)

        // Throttle Interval 子菜单
        let throttleItem = NSMenuItem(title: "Throttle Interval", action: nil, keyEquivalent: "")
        throttleItem.tag = throttleMenuTag
        throttleItem.submenu = NSMenu()
        menu.addItem(throttleItem)

        // Input Cooldown 子菜单
        let cooldownItem = NSMenuItem(title: "Input Cooldown", action: nil, keyEquivalent: "")
        cooldownItem.tag = cooldownMenuTag
        cooldownItem.submenu = NSMenu()
        menu.addItem(cooldownItem)

        // Persistent Hint Mode 开关
        let persistentItem = NSMenuItem(title: "Persistent Hint Mode", action: #selector(togglePersistentHintMode(_:)), keyEquivalent: "")
        persistentItem.tag = persistentHintModeTag
        menu.addItem(persistentItem)

        menu.addItem(NSMenuItem.separator())

        // 禁用自动激活选项
        let pauseMenu = NSMenuItem(title: "Pause Auto-Activation", action: nil, keyEquivalent: "")
        let pauseSubmenu = NSMenu()
        pauseSubmenu.addItem(NSMenuItem(title: "30 Minutes", action: #selector(pauseAutoActivation30m), keyEquivalent: ""))
        pauseSubmenu.addItem(NSMenuItem(title: "1 Hour", action: #selector(pauseAutoActivation1h), keyEquivalent: ""))
        pauseMenu.submenu = pauseSubmenu
        menu.addItem(pauseMenu)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate — 每次打开菜单时刷新动态内容

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildIgnoredAppsSubmenu()
        rebuildThrottleSubmenu()
        rebuildCooldownSubmenu()
        updatePersistentHintModeItem()
    }

    private func rebuildIgnoredAppsSubmenu() {
        guard let menu = statusItem.menu,
              let item = menu.item(withTag: ignoredAppsMenuTag),
              let submenu = item.submenu else { return }

        submenu.removeAllItems()

        let knownApps = badgeMonitor?.knownApps ?? []
        let ignoredIds = badgeMonitor?.ignoredBundleIds ?? []

        if knownApps.isEmpty {
            let placeholder = NSMenuItem(title: "(No apps detected yet)", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
        } else {
            for app in knownApps {
                let mi = NSMenuItem(title: app.name, action: #selector(toggleIgnoredApp(_:)), keyEquivalent: "")
                mi.representedObject = app.bundleId
                mi.state = ignoredIds.contains(app.bundleId) ? .on : .off
                submenu.addItem(mi)
            }
        }

        // 如果有已持久化但当前不在 Dock 的 ignored app，也展示出来
        let knownBundleIds = Set(knownApps.map(\.bundleId))
        let extraIgnored = ignoredIds.filter { !knownBundleIds.contains($0) }.sorted()
        if !extraIgnored.isEmpty {
            submenu.addItem(NSMenuItem.separator())
            for bundleId in extraIgnored {
                let displayName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.localizedName ?? bundleId
                let mi = NSMenuItem(title: displayName, action: #selector(toggleIgnoredApp(_:)), keyEquivalent: "")
                mi.representedObject = bundleId
                mi.state = .on
                submenu.addItem(mi)
            }
        }
    }

    private func rebuildThrottleSubmenu() {
        guard let menu = statusItem.menu,
              let item = menu.item(withTag: throttleMenuTag),
              let submenu = item.submenu else { return }

        submenu.removeAllItems()

        let current = badgeMonitor?.throttleInterval ?? loadThrottleInterval()
        for option in throttleOptions {
            let mi = NSMenuItem(title: option.title, action: #selector(selectThrottle(_:)), keyEquivalent: "")
            mi.representedObject = option.value
            mi.state = (current == option.value) ? .on : .off
            submenu.addItem(mi)
        }
    }

    private func rebuildCooldownSubmenu() {
        guard let menu = statusItem.menu,
              let item = menu.item(withTag: cooldownMenuTag),
              let submenu = item.submenu else { return }

        submenu.removeAllItems()

        let current = badgeMonitor?.inputCooldown ?? loadInputCooldown()
        for option in cooldownOptions {
            let mi = NSMenuItem(title: option.title, action: #selector(selectCooldown(_:)), keyEquivalent: "")
            mi.representedObject = option.value
            mi.state = (current == option.value) ? .on : .off
            submenu.addItem(mi)
        }
    }

    private func updatePersistentHintModeItem() {
        guard let menu = statusItem.menu,
              let item = menu.item(withTag: persistentHintModeTag) else { return }
        item.state = (vimModeController?.persistentMode ?? false) ? .on : .off
    }

    // MARK: - Menu Actions

    @objc private func togglePersistentHintMode(_ sender: NSMenuItem) {
        let newValue = !(vimModeController?.persistentMode ?? false)
        vimModeController?.persistentMode = newValue
        userDefaults.set(newValue, forKey: persistentHintModeKey)
        print("[Reddot] Persistent hint mode: \(newValue)")
    }

    @objc private func toggleIgnoredApp(_ sender: NSMenuItem) {
        guard let bundleId = sender.representedObject as? String else { return }

        var ignored = badgeMonitor?.ignoredBundleIds ?? loadIgnoredApps()
        if ignored.contains(bundleId) {
            ignored.remove(bundleId)
        } else {
            ignored.insert(bundleId)
        }

        badgeMonitor?.ignoredBundleIds = ignored
        saveIgnoredApps(ignored)
        print("[Reddot] Ignored apps updated: \(ignored)")
    }

    @objc private func selectThrottle(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? TimeInterval else { return }
        badgeMonitor?.throttleInterval = value
        userDefaults.set(value, forKey: throttleIntervalKey)
        print("[Reddot] Throttle interval set to \(value)s")
    }

    @objc private func selectCooldown(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? TimeInterval else { return }
        badgeMonitor?.inputCooldown = value
        userDefaults.set(value, forKey: inputCooldownKey)
        print("[Reddot] Input cooldown set to \(value)s")
    }

    // MARK: - Permissions

    private func checkAccessibilityPermission() -> Bool {
        // 先静默检查，不触发系统弹窗（prompt: false）
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
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

    // MARK: - Services

    func startServices() {
        vimModeController = VimModeController()
        vimModeController?.persistentMode = userDefaults.bool(forKey: persistentHintModeKey)
        vimModeController?.start()

        let ignoredApps = loadIgnoredApps()
        let throttle = loadThrottleInterval()
        let cooldown = loadInputCooldown()

        badgeMonitor = DockBadgeMonitor(
            throttleInterval: throttle,
            inputCooldown: cooldown,
            ignoredBundleIds: ignoredApps
        ) { [weak self] appName, bundleId, badgeValue in
            print("[Reddot] Badge detected: \(appName) (\(bundleId)) = \(badgeValue)")
            DispatchQueue.main.async {
                if self?.isAutoActivationDisabled() ?? false {
                    print("[Reddot] Auto-activation is paused, ignoring badge change")
                    return
                }
                Self.activateApp(bundleId: bundleId)
            }
        }
        badgeMonitor?.startMonitoring()
        updateMenu(monitoring: true)
        print("[Reddot] Services started, monitoring Dock badges...")
    }

    private static func activateApp(bundleId: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            print("[Reddot] App not found for bundleId: \(bundleId)")
            return
        }

        // 先尝试常规激活
        let success = app.activate()
        print("[Reddot] Activate \(app.localizedName ?? bundleId): \(success)")

        // 如果 app 没有可见窗口（用户已关闭所有窗口），通过 open 重新打开
        if !appHasVisibleWindow(app) {
            print("[Reddot] No visible window for \(app.localizedName ?? bundleId), reopening...")
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                NSWorkspace.shared.openApplication(at: url,
                                                   configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    /// 检查 app 是否有可见窗口（通过 Accessibility API）
    private static func appHasVisibleWindow(_ app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return false
        }
        // 至少有一个非最小化的窗口
        for window in windows {
            var minimizedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
               let minimized = minimizedRef as? Bool, minimized {
                continue
            }
            return true
        }
        return false
    }
    
    private func isAutoActivationDisabled() -> Bool {
        guard let disableUntil = userDefaults.object(forKey: autoActivationDisableUntilKey) as? Date else {
            return false
        }
        return Date() < disableUntil
    }
    
    @objc private func pauseAutoActivation30m() {
        let disableUntil = Date().addingTimeInterval(30 * 60)
        userDefaults.set(disableUntil, forKey: autoActivationDisableUntilKey)
        print("[Reddot] Auto-activation paused until \(disableUntil)")
    }
    
    @objc private func pauseAutoActivation1h() {
        let disableUntil = Date().addingTimeInterval(60 * 60)
        userDefaults.set(disableUntil, forKey: autoActivationDisableUntilKey)
        print("[Reddot] Auto-activation paused until \(disableUntil)")
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

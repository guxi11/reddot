//
//  DockBadgeMonitor.swift
//  Reddot
//
//  通过 Accessibility API 轮询 Dock 进程，检测应用 Badge 变化
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Badge 变化回调: (appName, bundleId, badgeValue)
typealias BadgeChangeHandler = (String, String, String) -> Void

class DockBadgeMonitor {
    private var timer: Timer?
    private var previousBadges: [String: String] = [:] // bundleId -> badgeValue
    private let onBadgeChange: BadgeChangeHandler
    private let pollingInterval: TimeInterval = 1.0

    // MARK: - 节流: 同一 app 首次变化立即触发，之后冷却期内忽略
    var throttleInterval: TimeInterval
    /// bundleId -> 上次触发回调的时间
    private var lastFireTime: [String: Date] = [:]

    // MARK: - 输入抑制: 用户正在输入或输入结束后 cooldown 内不触发
    var inputCooldown: TimeInterval

    // MARK: - 忽略列表
    var ignoredBundleIds: Set<String> = []

    /// 最近扫描到的有 Badge 的 app 列表 (name, bundleId)
    var knownApps: [(name: String, bundleId: String)] {
        return previousBadges.keys.sorted().map { bundleId in
            (name: appNameForBundleId(bundleId), bundleId: bundleId)
        }
    }
    private var eventMonitor: Any?
    /// 上次键盘/输入事件的时间戳
    private var lastInputTime: Date = .distantPast
    /// 当前是否处于 composing (marked text) 状态
    private var isComposing: Bool = false

    init(throttleInterval: TimeInterval = 10.0,
         inputCooldown: TimeInterval = 3.0,
         ignoredBundleIds: Set<String> = [],
         onBadgeChange: @escaping BadgeChangeHandler) {
        self.throttleInterval = throttleInterval
        self.inputCooldown = inputCooldown
        self.ignoredBundleIds = ignoredBundleIds
        self.onBadgeChange = onBadgeChange
    }

    func startMonitoring() {
        previousBadges = scanDockBadges()
        print("[Reddot] DockBadgeMonitor started. Initial badges: \(previousBadges)")

        startInputMonitoring()

        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        lastFireTime.removeAll()
        stopInputMonitoring()
    }

    // MARK: - 输入监听

    private func startInputMonitoring() {
        // 监听全局键盘事件 (keyDown + flagsChanged 覆盖大部分输入场景)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self = self else { return }
            self.lastInputTime = Date()

            // 通过 Accessibility 检测当前焦点元素是否有 marked text (composing)
            self.isComposing = self.checkComposingState()
        }
    }

    private func stopInputMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// 检测当前聚焦文本输入框是否处于 composing (marked text) 状态
    private func checkComposingState() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success else {
            return false
        }
        let focused = focusedRef as! AXUIElement

        // AXMarkedTextRange 非空 => 正在 composing
        var markedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, "AXMarkedTextRange" as CFString, &markedRef) == .success,
           markedRef != nil {
            return true
        }
        return false
    }

    /// 用户是否处于「输入中」状态：composing 或距离上次按键不超过 cooldown
    private var isUserTyping: Bool {
        if isComposing { return true }
        return Date().timeIntervalSince(lastInputTime) < inputCooldown
    }

    // MARK: - 轮询 & 节流

    private func poll() {
        let currentBadges = scanDockBadges()

        for (bundleId, badgeValue) in currentBadges {
            // 忽略列表中的 app 不触发回调
            guard !ignoredBundleIds.contains(bundleId) else { continue }

            let previousValue = previousBadges[bundleId]
            if previousValue == nil || previousValue != badgeValue {
                throttledCallback(bundleId: bundleId, badgeValue: badgeValue)
            }
        }

        previousBadges = currentBadges
    }

    private func throttledCallback(bundleId: String, badgeValue: String) {
        let now = Date()

        // 节流：如果该 bundleId 在冷却期内，直接忽略
        if let lastFire = lastFireTime[bundleId],
           now.timeIntervalSince(lastFire) < throttleInterval {
            return
        }

        let appName = appNameForBundleId(bundleId)
        fireWhenIdle(appName: appName, bundleId: bundleId, badgeValue: badgeValue)
    }

    /// 如果用户正在输入则延迟重试，否则立即触发并记录节流时间
    private func fireWhenIdle(appName: String, bundleId: String, badgeValue: String) {
        if isUserTyping {
            // 用户还在输入，0.5s 后再检查
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.fireWhenIdle(appName: appName, bundleId: bundleId, badgeValue: badgeValue)
            }
            return
        }
        lastFireTime[bundleId] = Date()
        onBadgeChange(appName, bundleId, badgeValue)
    }

    // MARK: - Dock Badge 扫描

    private func scanDockBadges() -> [String: String] {
        var badges: [String: String] = [:]

        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return badges
        }

        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return badges
        }

        for child in children {
            var roleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
                  let role = roleRef as? String, role == "AXList" else {
                continue
            }

            var listChildrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &listChildrenRef) == .success,
                  let listChildren = listChildrenRef as? [AXUIElement] else {
                continue
            }

            for dockItem in listChildren {
                var statusRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, "AXStatusLabel" as CFString, &statusRef) == .success,
                      let badgeText = statusRef as? String, !badgeText.isEmpty else {
                    continue
                }

                if let bundleId = bundleIdForDockItem(dockItem) {
                    badges[bundleId] = badgeText
                }
            }
        }

        return badges
    }

    private func bundleIdForDockItem(_ item: AXUIElement) -> String? {
        var urlRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRef) == .success else {
            return nil
        }

        let urlString: String?
        if let str = urlRef as? String {
            urlString = str
        } else if let cfURL = urlRef as! CFURL? {
            urlString = CFURLGetString(cfURL) as String?
        } else {
            return nil
        }

        guard let urlStr = urlString, let url = URL(string: urlStr) else {
            return nil
        }

        if let bundle = Bundle(url: url) {
            return bundle.bundleIdentifier
        }

        return nil
    }

    private func appNameForBundleId(_ bundleId: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            return app.localizedName ?? bundleId
        }
        return bundleId
    }
}

//
//  DockBadgeMonitor.swift
//  Reddot
//
//  通过 Accessibility API 轮询 Dock 进程，检测应用 Badge 变化
//

import AppKit
import ApplicationServices

/// Badge 变化回调: (appName, bundleId, badgeValue)
typealias BadgeChangeHandler = (String, String, String) -> Void

class DockBadgeMonitor {
    private var timer: Timer?
    private var previousBadges: [String: String] = [:] // bundleId -> badgeValue
    private let onBadgeChange: BadgeChangeHandler
    private let pollingInterval: TimeInterval = 1.0

    init(onBadgeChange: @escaping BadgeChangeHandler) {
        self.onBadgeChange = onBadgeChange
    }

    func startMonitoring() {
        // 先做一次初始快照，避免启动时误触发
        previousBadges = scanDockBadges()

        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let currentBadges = scanDockBadges()

        for (bundleId, badgeValue) in currentBadges {
            let previousValue = previousBadges[bundleId]
            // 新出现的 badge 或 badge 数值增加
            if previousValue == nil || previousValue != badgeValue {
                let appName = appNameForBundleId(bundleId)
                onBadgeChange(appName, bundleId, badgeValue)
            }
        }

        previousBadges = currentBadges
    }

    /// 通过 AXUIElement 遍历 Dock 中的应用，读取 Badge (statusLabel)
    private func scanDockBadges() -> [String: String] {
        var badges: [String: String] = [:]

        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return badges
        }

        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

        // Dock 的子元素结构: AXApplication -> AXList -> AXDockItem(s)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return badges
        }

        for child in children {
            // 找到 AXList (Dock 的主要列表区域)
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
                // 读取 AXStatusLabel — 这是 Badge 文本
                var statusRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, "AXStatusLabel" as CFString, &statusRef) == .success,
                      let badgeText = statusRef as? String, !badgeText.isEmpty else {
                    continue
                }

                // 获取 Dock item 的 URL 来确定 bundleId
                if let bundleId = bundleIdForDockItem(dockItem) {
                    badges[bundleId] = badgeText
                }
            }
        }

        return badges
    }

    /// 从 Dock item 的 AXUrl 属性获取对应 app 的 bundleId
    private func bundleIdForDockItem(_ item: AXUIElement) -> String? {
        var urlRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRef) == .success else {
            return nil
        }

        // AXUrl 可能是 CFString 或 CFURL
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

        // file:///Applications/XXX.app/ -> 从 Bundle 读取 bundleIdentifier
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

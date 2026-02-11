//
//  RedDotImageDetector.swift
//  Reddot
//
//  基于图像识别检测窗口中的红点：
//  ScreenCaptureKit 截取窗口 -> HSB 颜色过滤 -> 连通域分析 -> 形状过滤 -> 返回屏幕坐标
//

import AppKit
import ScreenCaptureKit

class RedDotImageDetector {

    /// 缓存屏幕缩放因子，避免每次切主线程获取
    private static var cachedScaleFactor: CGFloat = 0

    private static func getScaleFactor() async -> CGFloat {
        if cachedScaleFactor > 0 { return cachedScaleFactor }
        let sf = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        cachedScaleFactor = sf
        return sf
    }

    private static func ms(_ s: Double) -> String {
        return String(format: "%.0fms", s * 1000)
    }

    /// 异步检测前台应用窗口中的红点，返回屏幕坐标列表
    static func detectAsync() async -> [CGPoint] {
        let t0 = CFAbsoluteTimeGetCurrent()

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            print("[Reddot] No frontmost application")
            return []
        }

        // 获取可共享内容
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("[Reddot] Failed to get shareable content: \(error)")
            return []
        }
        let t1 = CFAbsoluteTimeGetCurrent()

        // 找到前台应用的主窗口
        guard let targetWindow = content.windows.first(where: {
            $0.owningApplication?.processID == frontApp.processIdentifier
            && $0.isOnScreen
            && $0.frame.width > 50
            && $0.frame.height > 50
        }) else {
            print("[Reddot] No matching window found")
            return []
        }

        let windowFrame = targetWindow.frame

        // 配置截图：只截取目标窗口
        let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        let config = SCStreamConfiguration()
        // Retina 屏幕下需要用像素尺寸，否则截图是 2x 但 config 是 1x，导致缩放错误
        let scaleFactor = await getScaleFactor()
        config.width = Int(windowFrame.width * scaleFactor)
        config.height = Int(windowFrame.height * scaleFactor)
        config.scalesToFit = false
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // 截取单帧
        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            print("[Reddot] Screenshot failed: \(error)")
            return []
        }
        print("[Reddot] Screenshot: \(cgImage.width)x\(cgImage.height)")
        let t2 = CFAbsoluteTimeGetCurrent()

        // 在图像中检测红点
        let imagePoints = findRedDots(in: cgImage)
        let t3 = CFAbsoluteTimeGetCurrent()

        print("[Reddot] \(imagePoints.count) dots | content=\(ms(t1-t0)) capture=\(ms(t2-t1)) detect=\(ms(t3-t2)) total=\(ms(t3-t0))")

        // 图像坐标 -> 屏幕坐标
        // ScreenCaptureKit 的 frame 是 Quartz 坐标系（左上角原点）
        let scaleX = windowFrame.width / CGFloat(cgImage.width)
        let scaleY = windowFrame.height / CGFloat(cgImage.height)

        // SCWindow.frame 使用 Quartz 坐标系（左上角原点），CGEvent 鼠标坐标也是左上角原点
        // 所以直接用 windowFrame.origin + 图像内偏移即可

        return imagePoints.map { pt in
            CGPoint(
                x: windowFrame.origin.x + pt.x * scaleX,
                y: windowFrame.origin.y + pt.y * scaleY
            )
        }
    }

    // MARK: - 图像分析

    /// 在 CGImage 中查找红点，返回图像坐标系中的中心点列表
    private static func findRedDots(in image: CGImage) -> [CGPoint] {
        let width = image.width
        let height = image.height
        let totalPixels = width * height

        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return []
        }

        let bytesPerRow = image.bytesPerRow

        // 1. 生成红色掩码（UInt8: 0=非红, 1=红）+ 同时计数
        //    ScreenCaptureKit 固定输出 BGRA little-endian，直接按 BGRA 解析
        let maskPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: totalPixels)
        maskPtr.initialize(repeating: 0, count: totalPixels)
        defer { maskPtr.deallocate() }

        var redPixelCount = 0

        for y in 0..<height {
            let rowBase = y * bytesPerRow
            let maskRowBase = y * width
            for x in 0..<width {
                let offset = rowBase + x * 4  // BGRA, 4 bytes per pixel
                let b = ptr[offset]
                let g = ptr[offset + 1]
                let r = ptr[offset + 2]

                if isRedPixelFast(r: r, g: g, b: b) {
                    maskPtr[maskRowBase + x] = 1
                    redPixelCount += 1
                }
            }
        }

        // 2. 连通域标记 (4-连通 flood fill)
        //    labels: 0=未标记, >0=标签号
        let labelsPtr = UnsafeMutablePointer<Int32>.allocate(capacity: totalPixels)
        labelsPtr.initialize(repeating: 0, count: totalPixels)
        defer { labelsPtr.deallocate() }

        var currentLabel: Int32 = 0
        var regions: [(minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int)] = []
        // 预分配 flood fill 栈，避免反复 append/removeLast 的堆分配
        var stack: [(Int, Int)] = []
        stack.reserveCapacity(1024)

        for y in 0..<height {
            let maskRowBase = y * width
            for x in 0..<width {
                let idx = maskRowBase + x
                if maskPtr[idx] == 1 && labelsPtr[idx] == 0 {
                    currentLabel += 1
                    // inline flood fill
                    stack.append((x, y))
                    var minX = x, minY = y, maxX = x, maxY = y
                    var count = 0

                    while !stack.isEmpty {
                        let (cx, cy) = stack.removeLast()
                        guard cx >= 0 && cx < width && cy >= 0 && cy < height else { continue }
                        let fIdx = cy * width + cx
                        guard maskPtr[fIdx] == 1 && labelsPtr[fIdx] == 0 else { continue }

                        labelsPtr[fIdx] = currentLabel
                        count += 1
                        if cx < minX { minX = cx }
                        if cy < minY { minY = cy }
                        if cx > maxX { maxX = cx }
                        if cy > maxY { maxY = cy }

                        stack.append((cx + 1, cy))
                        stack.append((cx - 1, cy))
                        stack.append((cx, cy + 1))
                        stack.append((cx, cy - 1))
                    }

                    regions.append((minX, minY, maxX, maxY, count))
                }
            }
        }

        print("[Reddot] Red pixels: \(redPixelCount), regions: \(regions.count)")

        // 3. 合并邻近区域
        let merged = mergeNearbyRegions(regions, gap: 3)

        // 4. 形状过滤
        var results: [CGPoint] = []

        for region in merged {
            let rw = region.maxX - region.minX + 1
            let rh = region.maxY - region.minY + 1
            let boxArea = rw * rh

            let area = region.count
            let aspect = CGFloat(rw) / CGFloat(rh)
            let fillRatio = CGFloat(area) / CGFloat(boxArea)

            if area < 20 { continue }
            if area > 3000 { continue }
            if rw < 5 || rh < 5 { continue }
            if rw > 60 || rh > 40 { continue }
            if aspect < 0.5 || aspect > 3.0 { continue }
            if fillRatio < 0.35 { continue }

            let cx = CGFloat(region.minX + region.maxX) / 2.0
            let cy = CGFloat(region.minY + region.maxY) / 2.0
            results.append(CGPoint(x: cx, y: cy))
        }

        // 按位置稳定排序：先按 y 分行（容差 20px），同行按 x 从左到右
        results.sort { a, b in
            let rowA = Int(a.y / 20)
            let rowB = Int(b.y / 20)
            if rowA != rowB { return rowA < rowB }
            return a.x < b.x
        }

        return results
    }

    /// 合并 bounding box 接近的区域（间距 <= gap 像素）
    /// 带数字的 badge 红色背景会被白色文字切成多个碎片，合并后恢复为一个整体
    private static func mergeNearbyRegions(
        _ regions: [(minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int)],
        gap: Int
    ) -> [(minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int)] {
        guard !regions.isEmpty else { return [] }

        var merged = regions
        var changed = true

        while changed {
            changed = false
            var i = 0
            while i < merged.count {
                var j = i + 1
                while j < merged.count {
                    let a = merged[i]
                    let b = merged[j]

                    // 检查两个 bounding box 是否在 gap 范围内相邻或重叠
                    let overlapX = a.minX <= b.maxX + gap && b.minX <= a.maxX + gap
                    let overlapY = a.minY <= b.maxY + gap && b.minY <= a.maxY + gap

                    if overlapX && overlapY {
                        // 合并
                        merged[i] = (
                            minX: min(a.minX, b.minX),
                            minY: min(a.minY, b.minY),
                            maxX: max(a.maxX, b.maxX),
                            maxY: max(a.maxY, b.maxY),
                            count: a.count + b.count
                        )
                        merged.remove(at: j)
                        changed = true
                    } else {
                        j += 1
                    }
                }
                i += 1
            }
        }

        return merged
    }

    /// 判断一个像素是否为"红色"（纯整数运算，避免浮点开销）
    /// 等效于 HSB: H ∈ [345°,360°]∪[0°,15°], S ≥ 0.60, V ≥ 0.50
    @inline(__always)
    private static func isRedPixelFast(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        // V ≥ 0.50 → maxC >= 128
        let maxC = max(r, g, b)
        if maxC < 128 { return false }

        // S ≥ 0.60 → delta/maxC >= 0.6 → delta*255 >= maxC*153 (153 = 0.6*255)
        let minC = min(r, g, b)
        let delta = Int(maxC) - Int(minC)
        if delta == 0 { return false }
        if delta * 255 < Int(maxC) * 153 { return false }

        // R 必须是最大分量（红色色相区间）
        if r != maxC { return false }

        // H 计算: hue6 = (g - b) / delta，范围 [-1, 1] 对应 [330°, 30°] 附近
        // hue_deg = hue6 * 60
        // 我们要 hue <= 15° || hue >= 345°
        // → hue6 <= 0.25 || hue6 >= 5.75  (在 [0,6) 范围)
        // → (g - b) / delta <= 0.25 || (g - b) / delta + 6 >= 5.75 (当 g < b)
        // → (g - b) * 4 <= delta || (g - b) * 4 >= -delta  (当 g < b，即 (g-b+6)*60 >= 345 → (g-b)/delta >= -0.25)
        // 简化: |g - b| * 4 <= delta
        let diff = abs(Int(g) - Int(b))
        return diff * 4 <= delta
    }
}

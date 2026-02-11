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

    /// 异步检测前台应用窗口中的红点，返回屏幕坐标列表
    static func detectAsync() async -> [CGPoint] {
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
        let scaleFactor = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
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
        print("[Reddot] Screenshot: \(cgImage.width)x\(cgImage.height) scaleFactor=\(scaleFactor)")

        // 在图像中检测红点
        let imagePoints = findRedDots(in: cgImage)
        print("[Reddot] findRedDots returned \(imagePoints.count) image points")

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

        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return []
        }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow

        // 判断像素格式（BGRA vs RGBA）
        let isBGRA = image.bitmapInfo.contains(.byteOrder32Little)

        // 1. 生成红色掩码
        var redMask = [Bool](repeating: false, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r: CGFloat
                let g: CGFloat
                let b: CGFloat
                if isBGRA {
                    b = CGFloat(ptr[offset]) / 255.0
                    g = CGFloat(ptr[offset + 1]) / 255.0
                    r = CGFloat(ptr[offset + 2]) / 255.0
                } else {
                    r = CGFloat(ptr[offset]) / 255.0
                    g = CGFloat(ptr[offset + 1]) / 255.0
                    b = CGFloat(ptr[offset + 2]) / 255.0
                }

                if isRedPixel(r: r, g: g, b: b) {
                    redMask[y * width + x] = true
                }
            }
        }

        let redPixelCount = redMask.filter { $0 }.count

        // 2. 连通域标记 (4-连通 flood fill)
        var labels = [Int](repeating: 0, count: width * height)
        var currentLabel = 0
        var regions: [Int: (minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int)] = [:]

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                if redMask[idx] && labels[idx] == 0 {
                    currentLabel += 1
                    let region = floodFill(
                        mask: &redMask, labels: &labels,
                        startX: x, startY: y,
                        width: width, height: height,
                        label: currentLabel
                    )
                    regions[currentLabel] = region
                }
            }
        }

        print("[Reddot] Red pixels: \(redPixelCount), regions: \(regions.count)")

        // 3. 合并邻近区域（带数字的 badge 内部白色文字会把红色背景切成多个碎片）
        let merged = mergeNearbyRegions(Array(regions.values), gap: 3)
        print("[Reddot] After merge: \(merged.count) candidates")

        // 4. 形状过滤
        var results: [CGPoint] = []

        for region in merged {
            let rw = region.maxX - region.minX + 1
            let rh = region.maxY - region.minY + 1
            let boxArea = rw * rh

            let area = region.count
            let aspect = CGFloat(rw) / CGFloat(rh)
            // 用 bounding box 面积算填充率，合并后的 badge 红色占 bbox 约 50-80%
            let fillRatio = CGFloat(area) / CGFloat(boxArea)

            // 纯红点：小面积、高填充率
            // 数字 badge：较大面积、红色占 bbox 40%+ (白字占了部分空间)
            if area < 20 { continue }
            if area > 3000 { continue }
            if rw < 5 || rh < 5 { continue }
            if rw > 60 || rh > 40 { continue }

            // 宽高比：纯红点接近 1:1，数字 badge 可能稍宽（如 "99+"）
            if aspect < 0.5 || aspect > 3.0 { continue }

            // 填充率：纯红点 >0.55，数字 badge 红色部分占 bbox 约 0.35+
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

    /// 判断一个像素是否为"红色"（HSB 空间）
    private static func isRedPixel(r: CGFloat, g: CGFloat, b: CGFloat) -> Bool {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC

        if maxC < 0.50 { return false }

        let saturation = maxC > 0 ? delta / maxC : 0
        if saturation < 0.60 { return false }

        guard delta > 0 else { return false }
        var hue: CGFloat
        if maxC == r {
            hue = (g - b) / delta
            if hue < 0 { hue += 6 }
        } else if maxC == g {
            hue = 2 + (b - r) / delta
        } else {
            hue = 4 + (r - g) / delta
        }
        hue *= 60

        return hue <= 15 || hue >= 345
    }

    /// 4-连通 flood fill
    private static func floodFill(
        mask: inout [Bool], labels: inout [Int],
        startX: Int, startY: Int,
        width: Int, height: Int,
        label: Int
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int) {
        var stack = [(startX, startY)]
        var minX = startX, minY = startY, maxX = startX, maxY = startY
        var count = 0

        while !stack.isEmpty {
            let (x, y) = stack.removeLast()
            let idx = y * width + x

            guard x >= 0 && x < width && y >= 0 && y < height else { continue }
            guard mask[idx] && labels[idx] == 0 else { continue }

            labels[idx] = label
            count += 1
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)

            stack.append((x + 1, y))
            stack.append((x - 1, y))
            stack.append((x, y + 1))
            stack.append((x, y - 1))
        }

        return (minX, minY, maxX, maxY, count)
    }
}

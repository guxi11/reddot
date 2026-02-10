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

    /// 检测前台应用窗口中的红点，返回屏幕坐标列表（同步阻塞调用）
    static func detect() -> [CGPoint] {
        // ScreenCaptureKit 是异步 API，用信号量做同步桥接
        var result: [CGPoint] = []
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            result = await detectAsync()
            semaphore.signal()
        }

        semaphore.wait()
        return result
    }

    private static func detectAsync() async -> [CGPoint] {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return [] }

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
            return []
        }

        let windowFrame = targetWindow.frame

        // 配置截图：只截取目标窗口
        let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        let config = SCStreamConfiguration()
        config.width = Int(windowFrame.width)
        config.height = Int(windowFrame.height)
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

        // 在图像中检测红点
        let imagePoints = findRedDots(in: cgImage)

        // 图像坐标 -> 屏幕坐标
        // ScreenCaptureKit 的 frame 是 Quartz 坐标系（左上角原点）
        let scaleX = windowFrame.width / CGFloat(cgImage.width)
        let scaleY = windowFrame.height / CGFloat(cgImage.height)

        // SCWindow.frame 使用屏幕坐标（左上角原点在 macOS Quartz 中是顶部），
        // 但 macOS 屏幕坐标实际以左下角为原点，SCKit 的 frame.origin.y 是从顶部算的
        guard let screen = NSScreen.main else { return [] }
        let screenHeight = screen.frame.height

        return imagePoints.map { pt in
            CGPoint(
                // x: 窗口左边 + 图像内偏移
                x: windowFrame.origin.x + pt.x * scaleX,
                // y: 需要从 Quartz(左上原点) 转为 CG 事件坐标(也是左上原点)
                y: (screenHeight - windowFrame.origin.y - windowFrame.height) + pt.y * scaleY
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
        let isBGRA = image.bitmapInfo.contains(.byteOrder32Little) ||
                     image.pixelFormatInfo == .packed ||
                     bytesPerPixel == 4 // ScreenCaptureKit 默认 BGRA

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

        // 3. 形状过滤
        var results: [CGPoint] = []

        for (_, region) in regions {
            let rw = region.maxX - region.minX + 1
            let rh = region.maxY - region.minY + 1

            // 面积过滤
            let area = region.count
            if area < 12 || area > 1300 { continue }

            // 宽高过滤
            if rw < 4 || rh < 4 { continue }
            if rw > 45 || rh > 45 { continue }

            // 宽高比接近 1:1
            let aspect = CGFloat(rw) / CGFloat(rh)
            if aspect < 0.4 || aspect > 2.5 { continue }

            // 填充率
            let fillRatio = CGFloat(area) / CGFloat(rw * rh)
            if fillRatio < 0.4 { continue }

            let cx = CGFloat(region.minX + region.maxX) / 2.0
            let cy = CGFloat(region.minY + region.maxY) / 2.0
            results.append(CGPoint(x: cx, y: cy))
        }

        return results
    }

    /// 判断一个像素是否为"红色"（HSB 空间）
    private static func isRedPixel(r: CGFloat, g: CGFloat, b: CGFloat) -> Bool {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC

        if maxC < 0.35 { return false }

        let saturation = maxC > 0 ? delta / maxC : 0
        if saturation < 0.45 { return false }

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

        return hue <= 25 || hue >= 335
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

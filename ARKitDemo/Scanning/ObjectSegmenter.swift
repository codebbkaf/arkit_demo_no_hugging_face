import CoreVideo
import Vision

/// 影像中某一個物體的遮罩。`labels` 是 Vision 輸出的實例標籤圖（0 為背景），
/// 解析度比原圖低，以正規化座標查詢。
nonisolated struct ObjectMask {
    var labels: [UInt8]
    var width: Int
    var height: Int
    /// 被選中的物體的標籤。
    var label: UInt8

    /// 正規化影像座標（0...1，左上為原點）是否落在物體上。
    func contains(x: Float, y: Float) -> Bool {
        let mx = min(max(Int(x * Float(width)), 0), width - 1)
        let my = min(max(Int(y * Float(height)), 0), height - 1)
        return labels[my * width + mx] == label
    }
}

/// 用 Vision 的前景主體分割，把畫面中央的物體從背景（桌面、牆）分離出來。
///
/// ARKit 自己的物體偵測只能辨識事先掃描建檔的物體；這裡要處理的是任意物體，
/// 所以用不需要事先訓練的主體分割。
nonisolated final class ObjectSegmenter {
    private let request = VNGenerateForegroundInstanceMaskRequest()

    /// 回傳畫面中央（準星）對到的物體；中央是背景時取最靠近中央的物體。
    /// 找不到任何物體時回傳 nil。
    func segment(image: CVPixelBuffer) -> ObjectMask? {
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }

        let buffer = observation.instanceMask
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        var labels = [UInt8](repeating: 0, count: width * height)
        labels.withUnsafeMutableBytes { destination in
            for y in 0..<height {
                (destination.baseAddress! + y * width).copyMemory(from: base + y * bytesPerRow, byteCount: width)
            }
        }

        guard let label = Self.labelNearCenter(labels, width: width, height: height) else { return nil }
        return ObjectMask(labels: labels, width: width, height: height, label: label)
    }

    /// 中央像素的標籤；若為背景，找距離中央最近、且在短邊 25% 以內的物體像素。
    private static func labelNearCenter(_ labels: [UInt8], width: Int, height: Int) -> UInt8? {
        let cx = width / 2
        let cy = height / 2
        let center = labels[cy * width + cx]
        if center != 0 { return center }

        let radius = min(width, height) / 4
        var best: UInt8?
        var bestDistance = radius * radius
        for y in max(cy - radius, 0)..<min(cy + radius, height) {
            for x in max(cx - radius, 0)..<min(cx + radius, width) {
                let value = labels[y * width + x]
                guard value != 0 else { continue }
                let distance = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                if distance < bestDistance {
                    bestDistance = distance
                    best = value
                }
            }
        }
        return best
    }
}

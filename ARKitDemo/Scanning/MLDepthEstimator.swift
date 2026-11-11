import CoreML
import CoreVideo
import Vision

/// 用 Depth Anything V2 Small 從單張 RGB 影像估計「相對」深度。
/// 模型輸出不是公尺，而是與 1/距離 呈線性關係的值（越近越大），
/// 需要用已知距離的點校正（見 `calibrate`）。
nonisolated final class MLDepthEstimator {
    static let modelName = "DepthAnythingV2SmallF16"

    /// Xcode 會把 `.mlpackage` 編譯成 bundle 內的 `.mlmodelc`。
    static var modelURL: URL? {
        Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
    }

    struct RelativeDepth {
        var values: [Float]
        var width: Int
        var height: Int
    }

    private let request: VNCoreMLRequest

    init?() {
        guard let url = Self.modelURL else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: configuration),
              let visionModel = try? VNCoreMLModel(for: model) else { return nil }
        request = VNCoreMLRequest(model: visionModel)
        // 整張影像線性縮放到模型輸入，輸出像素與原圖像素才是單純的比例對應
        request.imageCropAndScaleOption = .scaleFill
    }

    func estimate(image: CVPixelBuffer) -> RelativeDepth? {
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNPixelBufferObservation else { return nil }
        let output = observation.pixelBuffer
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(output) else { return nil }
        let width = CVPixelBufferGetWidth(output)
        let height = CVPixelBufferGetHeight(output)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(output)
        var values = [Float](repeating: 0, count: width * height)

        switch CVPixelBufferGetPixelFormatType(output) {
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16,
             kCVPixelFormatType_DisparityFloat16:
            for y in 0..<height {
                let row = (base + y * bytesPerRow).assumingMemoryBound(to: Float16.self)
                for x in 0..<width { values[y * width + x] = Float(row[x]) }
            }
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32,
             kCVPixelFormatType_DisparityFloat32:
            for y in 0..<height {
                let row = (base + y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                for x in 0..<width { values[y * width + x] = row[x] }
            }
        default:
            return nil
        }
        return RelativeDepth(values: values, width: width, height: height)
    }

    /// 用已知深度的樣本求 `1/深度 = a · 相對值 + b`，把整張圖轉成公尺深度（就地覆寫）。
    ///
    /// 做兩次最小平方：第一次擬合後丟掉殘差過大的樣本再擬合一次。
    /// 樣本太少、斜率不為正、或擬合誤差中位數超過 15% 時回傳 false，這一幀應該捨棄。
    static func calibrate(_ depth: inout RelativeDepth,
                          samples: [(relative: Float, metricDepth: Float)]) -> Bool {
        let minimumSamples = 12
        guard samples.count >= minimumSamples else { return false }
        var pairs = samples.map { (x: $0.relative, y: 1 / $0.metricDepth) }

        func fit(_ pairs: [(x: Float, y: Float)]) -> (a: Float, b: Float)? {
            let n = Float(pairs.count)
            let sx = pairs.reduce(0) { $0 + $1.x }
            let sy = pairs.reduce(0) { $0 + $1.y }
            let sxx = pairs.reduce(0) { $0 + $1.x * $1.x }
            let sxy = pairs.reduce(0) { $0 + $1.x * $1.y }
            let denominator = n * sxx - sx * sx
            guard abs(denominator) > 1e-9 else { return nil }
            let a = (n * sxy - sx * sy) / denominator
            return (a, (sy - a * sx) / n)
        }
        func relativeErrors(_ pairs: [(x: Float, y: Float)], _ line: (a: Float, b: Float)) -> [Float] {
            pairs.map { abs(line.a * $0.x + line.b - $0.y) / $0.y }
        }
        func median(_ values: [Float]) -> Float {
            values.sorted()[values.count / 2]
        }

        guard var line = fit(pairs) else { return false }
        let firstErrors = relativeErrors(pairs, line)
        let cutoff = max(2.5 * median(firstErrors), 0.05)
        pairs = zip(pairs, firstErrors).filter { $0.1 <= cutoff }.map(\.0)
        guard pairs.count >= minimumSamples, let refined = fit(pairs) else { return false }
        line = refined
        guard line.a > 0, median(relativeErrors(pairs, line)) < 0.15 else { return false }

        let minimumInverseDepth: Float = 1 / 20
        for i in depth.values.indices {
            let inverse = line.a * depth.values[i] + line.b
            depth.values[i] = inverse > minimumInverseDepth ? 1 / inverse : 0
        }
        return true
    }
}

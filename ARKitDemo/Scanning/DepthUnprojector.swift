import CoreVideo
import simd

/// 從 ARKit 的 `capturedImage`（雙平面 YCbCr）取某個像素的 RGB。
nonisolated struct YCbCrSampler {
    private let buffer: CVPixelBuffer
    private let lumaBase: UnsafePointer<UInt8>
    private let chromaBase: UnsafePointer<UInt8>
    private let lumaStride: Int
    private let chromaStride: Int
    let width: Int
    let height: Int

    /// 會鎖住 pixel buffer；用完必須呼叫 `unlock()`。
    init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return nil
        }
        self.buffer = buffer
        lumaBase = UnsafePointer(luma.assumingMemoryBound(to: UInt8.self))
        chromaBase = UnsafePointer(chroma.assumingMemoryBound(to: UInt8.self))
        lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        height = CVPixelBufferGetHeightOfPlane(buffer, 0)
    }

    func unlock() {
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }

    func color(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let px = min(max(x, 0), width - 1)
        let py = min(max(y, 0), height - 1)
        let luma = Float(lumaBase[py * lumaStride + px]) / 255
        let chromaIndex = (py / 2) * chromaStride + (px / 2) * 2
        let cb = Float(chromaBase[chromaIndex]) / 255 - 0.5
        let cr = Float(chromaBase[chromaIndex + 1]) / 255 - 0.5
        func byte(_ v: Float) -> UInt8 { UInt8(min(max(v, 0), 1) * 255) }
        return (byte(luma + 1.402 * cr), byte(luma - 0.3441 * cb - 0.7141 * cr), byte(luma + 1.772 * cb))
    }
}

/// 一張要反投影的深度圖。深度值單位為公尺，0 或非有限值代表無效。
nonisolated struct DepthMap {
    let values: UnsafePointer<Float32>
    /// 每列的 Float 個數（含 padding）。
    let rowStride: Int
    let width: Int
    let height: Int
    /// 選用：ARKit 深度信心值（0 低、1 中、2 高）。
    var confidence: UnsafePointer<UInt8>? = nil
    var confidenceStride: Int = 0
    /// 選用：只保留落在這個物體遮罩內的像素。
    var mask: ObjectMask? = nil
}

nonisolated enum DepthUnprojector {
    /// 把深度圖的每個像素轉成世界座標的點。
    ///
    /// 針孔相機模型：像素 (u, v)、深度 d 對應相機座標
    /// `x = (u - cx) · d / fx`、`y = -(v - cy) · d / fy`、`z = -d`
    /// （ARKit 相機座標 x 向右、y 向上、鏡頭朝 -z），再乘上相機的世界變換矩陣。
    ///
    /// - Parameters:
    ///   - intrinsics: 對應 `imageSize` 解析度的相機內參，會依深度圖大小縮放。
    ///   - step: 取樣間隔（像素）。
    ///   - edgeTolerance: 與右方／下方鄰居的深度差超過 `edgeTolerance × d` 的像素視為
    ///     物體邊緣的雜訊（flying pixels）而捨棄。
    static func unproject(depth: DepthMap,
                          color: YCbCrSampler,
                          intrinsics: simd_float3x3,
                          imageSize: SIMD2<Float>,
                          cameraTransform: simd_float4x4,
                          near: Float,
                          far: Float,
                          step: Int,
                          edgeTolerance: Float = 0.04) -> [PointVertex] {
        let scaleX = Float(depth.width) / imageSize.x
        let scaleY = Float(depth.height) / imageSize.y
        let fx = intrinsics[0][0] * scaleX
        let fy = intrinsics[1][1] * scaleY
        let cx = intrinsics[2][0] * scaleX
        let cy = intrinsics[2][1] * scaleY
        let colorScaleX = Float(color.width) / Float(depth.width)
        let colorScaleY = Float(color.height) / Float(depth.height)

        var result: [PointVertex] = []
        result.reserveCapacity((depth.width / step) * (depth.height / step))

        var v = 0
        while v < depth.height {
            let row = depth.values + v * depth.rowStride
            var u = 0
            while u < depth.width {
                defer { u += step }
                let d = row[u]
                guard d.isFinite, d >= near, d <= far else { continue }
                if let confidence = depth.confidence, confidence[v * depth.confidenceStride + u] < 2 {
                    continue
                }
                if let mask = depth.mask,
                   !mask.contains(x: (Float(u) + 0.5) / Float(depth.width),
                                  y: (Float(v) + 0.5) / Float(depth.height)) {
                    continue
                }
                let tolerance = edgeTolerance * d
                if u + step < depth.width, abs(row[u + step] - d) > tolerance { continue }
                if v + step < depth.height,
                   abs(depth.values[(v + step) * depth.rowStride + u] - d) > tolerance { continue }

                let local = SIMD4<Float>((Float(u) - cx) * d / fx, -(Float(v) - cy) * d / fy, -d, 1)
                let world = cameraTransform * local
                let c = color.color(x: Int(Float(u) * colorScaleX), y: Int(Float(v) * colorScaleY))
                result.append(PointVertex(x: world.x, y: world.y, z: world.z, r: c.r, g: c.g, b: c.b))
            }
            v += step
        }
        return result
    }

    /// 高密度反投影：在相鄰四個深度量測值之間做雙線性內插，每個深度像素輸出 `factor × factor` 個點。
    ///
    /// 深度感測器的解析度（TrueDepth 640×480）遠低於彩色影像，這樣可以把點補到接近彩色影像的
    /// 密度，每個點取自己位置的顏色。內插只在四個角都有效、且彼此深度差在 `edgeTolerance` 內
    /// 的格子裡進行，不會跨越物體邊緣；其餘有效像素仍輸出原本的單一點。
    ///
    /// `factor` 會自動調降，確保總點數不超過 `maxPoints`。
    static func unprojectDense(depth: DepthMap,
                               color: YCbCrSampler,
                               intrinsics: simd_float3x3,
                               imageSize: SIMD2<Float>,
                               cameraTransform: simd_float4x4,
                               near: Float,
                               far: Float,
                               factor requestedFactor: Int,
                               maxPoints: Int,
                               edgeTolerance: Float = 0.04) -> [PointVertex] {
        let width = depth.width
        let height = depth.height
        let scaleX = Float(width) / imageSize.x
        let scaleY = Float(height) / imageSize.y
        let fx = intrinsics[0][0] * scaleX
        let fy = intrinsics[1][1] * scaleY
        let cx = intrinsics[2][0] * scaleX
        let cy = intrinsics[2][1] * scaleY
        let colorScaleX = Float(color.width) / Float(width)
        let colorScaleY = Float(color.height) / Float(height)

        func value(_ u: Int, _ v: Int) -> Float {
            let d = depth.values[v * depth.rowStride + u]
            guard d.isFinite, d >= near, d <= far else { return 0 }
            if let confidence = depth.confidence, confidence[v * depth.confidenceStride + u] < 2 { return 0 }
            return d
        }
        func inMask(_ u: Float, _ v: Float) -> Bool {
            guard let mask = depth.mask else { return true }
            return mask.contains(x: (u + 0.5) / Float(width), y: (v + 0.5) / Float(height))
        }

        // 先數有效像素，決定不超過上限的最大倍率
        var valid = 0
        for v in 0..<height {
            for u in 0..<width where value(u, v) > 0 && inMask(Float(u), Float(v)) {
                valid += 1
            }
        }
        guard valid > 0 else { return [] }
        var factor = max(requestedFactor, 1)
        while factor > 1, valid * factor * factor > maxPoints { factor -= 1 }

        var result: [PointVertex] = []
        result.reserveCapacity(min(valid * factor * factor, maxPoints))

        func emit(_ u: Float, _ v: Float, _ d: Float) {
            let world = cameraTransform * SIMD4<Float>((u - cx) * d / fx, -(v - cy) * d / fy, -d, 1)
            let c = color.color(x: Int(u * colorScaleX), y: Int(v * colorScaleY))
            result.append(PointVertex(x: world.x, y: world.y, z: world.z, r: c.r, g: c.g, b: c.b))
        }

        let step = 1 / Float(factor)
        for v in 0..<height {
            for u in 0..<width {
                let d00 = value(u, v)
                guard d00 > 0 else { continue }
                var interpolate = false
                var d10: Float = 0, d01: Float = 0, d11: Float = 0
                if factor > 1, u + 1 < width, v + 1 < height {
                    d10 = value(u + 1, v)
                    d01 = value(u, v + 1)
                    d11 = value(u + 1, v + 1)
                    if d10 > 0, d01 > 0, d11 > 0 {
                        let low = min(min(d00, d10), min(d01, d11))
                        let high = max(max(d00, d10), max(d01, d11))
                        interpolate = high - low <= edgeTolerance * low
                    }
                }
                guard interpolate else {
                    if inMask(Float(u), Float(v)) { emit(Float(u), Float(v), d00) }
                    continue
                }
                for j in 0..<factor {
                    let ty = Float(j) * step
                    for i in 0..<factor {
                        let tx = Float(i) * step
                        let pu = Float(u) + tx
                        let pv = Float(v) + ty
                        guard inMask(pu, pv) else { continue }
                        let top = d00 + (d10 - d00) * tx
                        let bottom = d01 + (d11 - d01) * tx
                        emit(pu, pv, top + (bottom - top) * ty)
                    }
                }
            }
        }
        return result
    }

    /// 世界座標點 → 影像像素與深度。點在相機後方時回傳 nil。
    static func project(_ world: SIMD3<Float>,
                        worldToCamera: simd_float4x4,
                        intrinsics: simd_float3x3) -> (u: Float, v: Float, depth: Float)? {
        let local = worldToCamera * SIMD4<Float>(world, 1)
        let d = -local.z
        guard d > 0.01 else { return nil }
        let u = intrinsics[2][0] + intrinsics[0][0] * local.x / d
        let v = intrinsics[2][1] - intrinsics[1][1] * local.y / d
        return (u, v, d)
    }
}

/// 固定視角下把多幀深度逐像素平均，降低單幀的量測雜訊。
nonisolated struct DepthAccumulator {
    private(set) var width = 0
    private(set) var height = 0
    private(set) var frames = 0
    private var sum: [Float] = []
    private var count: [UInt16] = []
    private var lowest: [Float] = []
    private var highest: [Float] = []

    mutating func reset() {
        self = DepthAccumulator()
    }

    /// 加入一幀 Float32 公尺深度圖。
    mutating func add(_ depth: DepthMap) {
        if frames == 0 {
            width = depth.width
            height = depth.height
            let n = width * height
            sum = [Float](repeating: 0, count: n)
            count = [UInt16](repeating: 0, count: n)
            lowest = [Float](repeating: .greatestFiniteMagnitude, count: n)
            highest = [Float](repeating: 0, count: n)
        }
        guard depth.width == width, depth.height == height else { return }
        frames += 1
        for v in 0..<height {
            let row = depth.values + v * depth.rowStride
            for u in 0..<width {
                let d = row[u]
                guard d.isFinite, d > 0 else { continue }
                let i = v * width + u
                sum[i] += d
                count[i] += 1
                lowest[i] = min(lowest[i], d)
                highest[i] = max(highest[i], d)
            }
        }
    }

    /// 每個像素的平均深度。有效幀數不到一半、或各幀之間變動超過 4% 的像素
    /// （通常是物體邊緣）輸出 0，代表無效。
    func averaged() -> [Float] {
        let required = UInt16(max(1, (frames + 1) / 2))
        var result = [Float](repeating: 0, count: sum.count)
        for i in sum.indices where count[i] >= required {
            let mean = sum[i] / Float(count[i])
            if highest[i] - lowest[i] <= 0.04 * mean {
                result[i] = mean
            }
        }
        return result
    }
}

import Foundation
import simd

/// 點雲中的一個點：ARKit 世界座標（公尺，右手座標系，y 軸向上）加上 RGBA 顏色。
/// 記憶體配置固定為 16 bytes，直接作為 Metal vertex buffer 使用。
nonisolated struct PointVertex {
    var x: Float
    var y: Float
    var z: Float
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8 = 255

    var position: SIMD3<Float> { SIMD3(x, y, z) }
}

/// 與感測器無關的點雲儲存。以體素格去重：同一個體素只保留第一個點。
/// 掃描執行緒寫入、主執行緒讀取，所有存取都經過鎖。
nonisolated final class PointCloudStore: @unchecked Sendable {
    static let maxPoints = 2_000_000

    let voxelSize: Float

    private let lock = NSLock()
    private var points: [PointVertex] = []
    private var occupied = Set<UInt64>()
    private var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    private var generation = 0
    private var viewDirection: SIMD3<Float>?

    init(voxelSize: Float = 0.003) {
        self.voxelSize = voxelSize
    }

    /// 加入候選點，回傳實際新增的數量。
    @discardableResult
    func append(_ candidates: [PointVertex]) -> Int {
        guard !candidates.isEmpty else { return 0 }
        let inverse = 1 / voxelSize
        lock.lock()
        defer { lock.unlock() }
        var added = 0
        for point in candidates {
            if points.count >= Self.maxPoints { break }
            let p = point.position
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
            let key = Self.voxelKey(p * inverse)
            guard occupied.insert(key).inserted else { continue }
            points.append(point)
            minBound = simd_min(minBound, p)
            maxBound = simd_max(maxBound, p)
            added += 1
        }
        return added
    }

    /// 以一組點取代全部內容，不做體素去重（單次拍攝本來就是一個像素一個點）。
    /// - Parameter viewDirection: 從物體指向拍攝相機的方向，檢視器用它決定初始視角。
    func replace(with newPoints: [PointVertex], viewDirection: SIMD3<Float>? = nil) {
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        let kept = Array(newPoints.prefix(Self.maxPoints))
        for point in kept {
            lower = simd_min(lower, point.position)
            upper = simd_max(upper, point.position)
        }
        lock.lock()
        defer { lock.unlock() }
        points = kept
        occupied.removeAll(keepingCapacity: true)
        minBound = lower
        maxBound = upper
        self.viewDirection = viewDirection
        generation += 1
    }

    /// 從物體指向拍攝相機的方向；沒有時為 nil。
    var preferredViewDirection: SIMD3<Float>? {
        lock.lock()
        defer { lock.unlock() }
        return viewDirection
    }

    /// 每軸 21 bits，3 mm 體素時可涵蓋約 ±3 km。
    private static func voxelKey(_ scaled: SIMD3<Float>) -> UInt64 {
        let ix = UInt64(truncatingIfNeeded: Int64(scaled.x.rounded(.down))) & 0x1F_FFFF
        let iy = UInt64(truncatingIfNeeded: Int64(scaled.y.rounded(.down))) & 0x1F_FFFF
        let iz = UInt64(truncatingIfNeeded: Int64(scaled.z.rounded(.down))) & 0x1F_FFFF
        return (ix << 42) | (iy << 21) | iz
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return points.count
    }

    var isFull: Bool { count >= Self.maxPoints }

    /// 邊界框；沒有點時為 nil。
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        lock.lock()
        defer { lock.unlock() }
        return points.isEmpty ? nil : (minBound, maxBound)
    }

    /// `generation` 在每次清除後遞增，renderer 用它判斷 GPU buffer 是否要重新上傳。
    var state: (generation: Int, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (generation, points.count)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        points.removeAll(keepingCapacity: true)
        occupied.removeAll(keepingCapacity: true)
        minBound = SIMD3(repeating: .greatestFiniteMagnitude)
        maxBound = SIMD3(repeating: -.greatestFiniteMagnitude)
        viewDirection = nil
        generation += 1
    }

    /// 把 `start` 之後的點複製到 `destination`，回傳複製的點數。
    func copyPoints(from start: Int, to destination: UnsafeMutableRawPointer, maxCount: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = min(points.count - start, maxCount)
        guard n > 0 else { return 0 }
        points.withUnsafeBytes { raw in
            let stride = MemoryLayout<PointVertex>.stride
            destination.copyMemory(from: raw.baseAddress! + start * stride, byteCount: n * stride)
        }
        return n
    }

    func snapshot() -> [PointVertex] {
        lock.lock()
        defer { lock.unlock() }
        return points
    }
}

extension PointCloudStore {
    /// 示範用：表面有起伏的球體，讓沒有 ARKit 的環境（模擬器）也能試用檢視器。
    nonisolated static func demo() -> PointCloudStore {
        let store = PointCloudStore()
        let n = 120_000
        var points: [PointVertex] = []
        points.reserveCapacity(n)
        let golden = Float.pi * (3 - sqrt(5))
        for i in 0..<n {
            let y = 1 - 2 * (Float(i) + 0.5) / Float(n)
            let ring = sqrt(1 - y * y)
            let theta = golden * Float(i)
            let dir = SIMD3<Float>(cos(theta) * ring, y, sin(theta) * ring)
            let bump = 0.012 * sin(dir.x * 14) * sin(dir.y * 14) * sin(dir.z * 14)
            let p = dir * (0.15 + bump)
            let c = (dir * 0.5 + 0.5) * 255
            points.append(PointVertex(x: p.x, y: p.y, z: p.z, r: UInt8(c.x), g: UInt8(c.y), b: UInt8(c.z)))
        }
        store.append(points)
        return store
    }
}

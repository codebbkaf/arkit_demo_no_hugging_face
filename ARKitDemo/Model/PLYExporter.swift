import Foundation

/// 把點雲寫成 binary little-endian PLY（x y z 為 float 公尺，顏色為 uchar）。
/// MeshLab、CloudCompare、Blender 都能直接開啟。
nonisolated enum PLYExporter {
    static func data(for points: [PointVertex]) -> Data {
        let header = """
        ply
        format binary_little_endian 1.0
        comment ARKitDemo point cloud, units: meters, ARKit world space (y up)
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        let recordSize = 15
        var body = Data(count: points.count * recordSize)
        body.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for (i, p) in points.enumerated() {
                let record = base + i * recordSize
                record.storeBytes(of: p.x.bitPattern.littleEndian, as: UInt32.self)
                (record + 4).storeBytes(of: p.y.bitPattern.littleEndian, as: UInt32.self)
                (record + 8).storeBytes(of: p.z.bitPattern.littleEndian, as: UInt32.self)
                (record + 12).storeBytes(of: p.r, as: UInt8.self)
                (record + 13).storeBytes(of: p.g, as: UInt8.self)
                (record + 14).storeBytes(of: p.b, as: UInt8.self)
            }
        }
        return Data(header.utf8) + body
    }

    /// 寫到暫存目錄，回傳檔案位置。檔名含時間戳。
    static func write(_ points: [PointVertex]) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-\(formatter.string(from: Date())).ply")
        try data(for: points).write(to: url, options: .atomic)
        return url
    }
}

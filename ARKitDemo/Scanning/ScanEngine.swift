import ARKit
import AVFoundation
import CoreMotion
import simd

nonisolated enum ScanPhase {
    /// 即時預覽：每幀用目前的深度取代點雲，讓使用者看到會拍到什麼。
    case preview
    /// 拍攝中：收集多幀。
    case capturing
    /// 已拍攝：點雲凍結，等使用者檢視或重拍。
    case captured
}

nonisolated struct ScanStatus {
    var phase: ScanPhase = .preview
    /// 拍攝進度 0...1。
    var captureProgress: Float = 0
    var pointCount = 0
    /// 有值時代表目前無法取得可用的資料（追蹤不穩、初始化中…）。
    var trackingMessage: String?
    /// 開始執行後是否收過任何深度資料。
    var hasReceivedDepth = false
    /// 目前實際在用的深度來源與解析度，例如「LiDAR 768×576」。收到深度前為 nil。
    var depthSource: String?
    /// 補充訊息，例如拍攝時晃動、ML 模式校正失敗。
    var note: String?
    /// 已開啟「只保留物體」，但準星附近找不到物體。
    var objectMissing = false
    var error: String?
}

/// 執行 ARSession，從固定視角把深度轉成世界座標點並寫入 `PointCloudStore`。
///
/// 預覽時每幀即時取代點雲；按下拍攝後收集多幀、逐像素平均，再以全解析度反投影一次。
/// ARKit 在 `delegateQueue` 上回呼；實際運算在 `workQueue` 上做，同一時間只處理一幀，
/// 來不及處理的影格直接丟掉，避免囤積 ARFrame。
nonisolated final class ScanEngine: NSObject, ARSessionDelegate, @unchecked Sendable {
    let session = ARSession()
    let store: PointCloudStore
    let mode: ScanMode

    private let delegateQueue = DispatchQueue(label: "scan.delegate")
    private let workQueue = DispatchQueue(label: "scan.work", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var maxDistance: Float
    private var isolateObject = true
    private var currentStatus = ScanStatus()

    // 以下只在 workQueue 上存取
    private var accumulator = DepthAccumulator()
    private var featureFrames = 0
    private var captureStartTransform: simd_float4x4?
    private let segmenter = ObjectSegmenter()

    /// LiDAR 模式優先使用的高解析深度相機；不可用時為 nil，退回 ARKit 的 sceneDepth。
    private let lidarCamera: LiDARCamera?
    private let motion = CMMotionManager()
    private var latestPreview: PreviewFrame?

    /// 影格是否來自 ARSession（否則來自 `lidarCamera`）。
    var usesARSession: Bool { lidarCamera == nil }
    private var estimator: MLDepthEstimator?
    private var estimatorLoaded = false

    /// 拍攝時要平均的深度幀數。
    private var captureFrameCount: Int {
        switch mode {
        case .lidar: 15
        case .trueDepth: 10
        case .featurePoints: 30
        case .mlDepth: 1
        }
    }

    init(mode: ScanMode, store: PointCloudStore) {
        self.mode = mode
        self.store = store
        self.maxDistance = mode.defaultFar
        self.lidarCamera = mode == .lidar && LiDARCamera.isAvailable ? LiDARCamera() : nil
        super.init()
        session.delegate = self
        session.delegateQueue = delegateQueue
        lidarCamera?.onFrame = { [weak self] frame in self?.handleLiDARFrame(frame) }
        lidarCamera?.onError = { [weak self] message in self?.updateStatus { $0.error = message } }
    }

    /// 掃描畫面背景用的最新影格（僅 LiDAR 高解析模式）。
    func previewFrame() -> PreviewFrame? {
        lock.withLock { latestPreview }
    }

    // MARK: - 控制（主執行緒呼叫）

    func run() {
        if let lidarCamera {
            motion.deviceMotionUpdateInterval = 1 / 30
            motion.startDeviceMotionUpdates()
            lidarCamera.start()
            return
        }
        let configuration: ARConfiguration
        switch mode {
        case .lidar:
            let world = ARWorldTrackingConfiguration()
            world.frameSemantics.insert(.sceneDepth)
            configuration = world
        case .trueDepth:
            let face = ARFaceTrackingConfiguration()
            // 開啟後相機姿態含位置，拍攝時才偵測得到手機有沒有移動
            if ARFaceTrackingConfiguration.supportsWorldTracking {
                face.isWorldTrackingEnabled = true
            }
            configuration = face
        case .featurePoints, .mlDepth:
            configuration = ARWorldTrackingConfiguration()
        }
        // 不帶 resetTracking：從檢視器返回時沿用原本的世界座標，已拍的點才不會錯位
        session.run(configuration)
    }

    func pause() {
        // 拍到一半離開就當作沒拍
        lock.withLock {
            if currentStatus.phase == .capturing { currentStatus.phase = .preview }
        }
        if let lidarCamera {
            lidarCamera.stop()
            motion.stopDeviceMotionUpdates()
            return
        }
        session.pause()
    }

    /// 開始拍攝。
    func capture() {
        lock.withLock {
            guard currentStatus.phase == .preview else { return }
            currentStatus.phase = .capturing
            currentStatus.captureProgress = 0
            currentStatus.note = nil
        }
    }

    /// 丟掉拍攝結果，回到即時預覽。
    func retake() {
        lock.withLock {
            currentStatus.phase = .preview
            currentStatus.note = nil
        }
    }

    func setMaxDistance(_ value: Float) {
        lock.withLock { maxDistance = value }
    }

    /// 是否只保留準星對到的物體（去掉桌面與背景）。
    func setIsolateObject(_ value: Bool) {
        lock.withLock {
            isolateObject = value
            if !value { currentStatus.objectMissing = false }
        }
    }

    func status() -> ScanStatus {
        var status = lock.withLock { currentStatus }
        status.pointCount = store.count
        return status
    }

    private func updateStatus(_ change: (inout ScanStatus) -> Void) {
        lock.withLock { change(&currentStatus) }
    }

    /// 拍攝失敗：回到預覽並說明原因。
    private func failCapture(_ reason: String) {
        updateStatus {
            $0.phase = .preview
            $0.note = reason
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didFailWithError error: Error) {
        let message: String
        if let arError = error as? ARError, arError.code == .cameraUnauthorized {
            message = "沒有相機權限。請到「設定」開啟此 App 的相機權限。"
        } else {
            message = error.localizedDescription
        }
        updateStatus { $0.error = message }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 深度模式只需要單幀的深度與內參，不依賴位置追蹤；
        // 特徵點與 ML 模式需要 ARKit 追蹤正常才有特徵點。
        let needsTracking = mode == .featurePoints || mode == .mlDepth
        let tracking = needsTracking ? Self.trackingMessage(for: frame.camera.trackingState) : nil
        updateStatus { $0.trackingMessage = tracking }

        let (phase, far, isBusy, isolate) = lock.withLock {
            (currentStatus.phase, maxDistance, busy, isolateObject)
        }
        guard phase != .captured, !isBusy, tracking == nil else { return }

        // 只把需要的資料帶出去，不要讓 ARFrame 本身被背景工作留住
        let camera = frame.camera
        let input = FrameInput(
            image: frame.capturedImage,
            intrinsics: camera.intrinsics,
            imageSize: SIMD2(Float(camera.imageResolution.width), Float(camera.imageResolution.height)),
            transform: camera.transform,
            near: mode.nearDistance,
            far: far,
            capturing: phase == .capturing,
            isolate: isolate)

        let job: () -> Void
        switch mode {
        case .lidar:
            guard let sceneDepth = frame.sceneDepth else { return }
            let depthMap = sceneDepth.depthMap
            let confidenceMap = sceneDepth.confidenceMap
            job = { [weak self] in
                self?.processDepth(depthMap, confidence: confidenceMap, input: input, previewStep: 2)
            }
        case .trueDepth:
            // TrueDepth 約 15 fps，大部分影格沒有深度
            guard let depthData = frame.capturedDepthData else { return }
            job = { [weak self] in
                let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
                self?.processDepth(converted.depthDataMap, confidence: nil, input: input, previewStep: 3)
            }
        case .featurePoints:
            let featurePoints = frame.rawFeaturePoints?.points ?? []
            job = { [weak self] in self?.processFeatures(featurePoints, input: input) }
        case .mlDepth:
            let featurePoints = frame.rawFeaturePoints?.points ?? []
            job = { [weak self] in self?.processModel(featurePoints: featurePoints, input: input) }
        }

        lock.withLock { busy = true }
        workQueue.async { [weak self] in
            job()
            self?.lock.withLock { self?.busy = false }
        }
    }

    // MARK: - LiDAR 高解析相機

    private func handleLiDARFrame(_ frame: LiDARCamera.Frame) {
        let transform = gravityAlignedTransform()
        let preview = PreviewFrame(image: frame.image, intrinsics: frame.intrinsics,
                                   imageSize: frame.imageSize, cameraTransform: transform)
        let (phase, far, isBusy, isolate) = lock.withLock {
            latestPreview = preview
            return (currentStatus.phase, maxDistance, busy, isolateObject)
        }
        guard phase != .captured, !isBusy else { return }

        let input = FrameInput(
            image: frame.image, intrinsics: frame.intrinsics, imageSize: frame.imageSize,
            transform: transform, near: mode.nearDistance, far: far,
            capturing: phase == .capturing, isolate: isolate)
        let depth = frame.depth
        lock.withLock { busy = true }
        workQueue.async { [weak self] in
            // 深度約 768 寬，預覽每 4 個像素取一個
            self?.processDepth(depth, confidence: nil, input: input, previewStep: 4)
            self?.lock.withLock { self?.busy = false }
        }
    }

    /// 沒有 ARKit 追蹤時，用重力方向讓點雲的 y 軸朝上；位置固定在原點。
    private func gravityAlignedTransform() -> simd_float4x4 {
        guard let gravity = motion.deviceMotion?.gravity else { return matrix_identity_float4x4 }
        // 裝置座標（直向時 x 向右、y 向上）→ 相機座標（原生橫向：x 朝裝置底部、y 朝裝置右側）
        let down = SIMD3<Float>(Float(-gravity.y), Float(gravity.x), Float(gravity.z))
        guard simd_length(down) > 0.5 else { return matrix_identity_float4x4 }
        let up = -simd_normalize(down)
        // 相機朝 -z 看；讓世界的 z 軸盡量對著相機背後
        var back = SIMD3<Float>(0, 0, 1) - up * up.z
        if simd_length(back) < 0.05 { back = SIMD3<Float>(1, 0, 0) - up * up.x }
        back = simd_normalize(back)
        let right = simd_cross(up, back)
        // 列向量是世界座標軸在相機座標中的方向，所以這個矩陣把相機座標轉成世界座標
        return simd_float4x4(rows: [
            SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(0, 0, 0, 1),
        ])
    }

    private static func trackingMessage(for state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal:
            return nil
        case .notAvailable:
            return "追蹤尚未就緒"
        case .limited(let reason):
            switch reason {
            case .initializing: return "初始化中，請稍微左右移動手機"
            case .excessiveMotion: return "移動太快，請放慢"
            case .insufficientFeatures: return "環境特徵不足，請對準有紋理的地方或增加光線"
            case .relocalizing: return "重新定位中"
            @unknown default: return "追蹤受限"
            }
        }
    }

    // MARK: - 共用

    private struct FrameInput {
        let image: CVPixelBuffer
        let intrinsics: simd_float3x3
        let imageSize: SIMD2<Float>
        let transform: simd_float4x4
        let near: Float
        let far: Float
        let capturing: Bool
        let isolate: Bool

        /// 從物體指向相機的方向（相機的 +z 軸）。
        var viewDirection: SIMD3<Float> {
            simd_normalize(SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        }
    }

    /// 拍攝期間手機是否移動到會讓多幀平均變模糊的程度（約 1 cm 或 1.5°）。
    private static func hasMoved(from start: simd_float4x4, to end: simd_float4x4) -> Bool {
        let translation = simd_distance(start.columns.3, end.columns.3)
        let forwardStart = simd_normalize(SIMD3(start.columns.2.x, start.columns.2.y, start.columns.2.z))
        let forwardEnd = simd_normalize(SIMD3(end.columns.2.x, end.columns.2.y, end.columns.2.z))
        return translation > 0.01 || simd_dot(forwardStart, forwardEnd) < cos(1.5 * Float.pi / 180)
    }

    private static let objectMissingMessage = "準星附近找不到物體。請把準星對準要掃描的物體後重拍。"

    /// 依設定找出準星對到的物體。
    /// - Returns: `mask` 為 nil 且 `found` 為 true 代表沒有開啟物體隔離；
    ///   `found` 為 false 代表開啟了但找不到物體。
    private func objectMask(for input: FrameInput) -> (mask: ObjectMask?, found: Bool) {
        guard input.isolate else { return (nil, true) }
        let mask = segmenter.segment(image: input.image)
        updateStatus { $0.objectMissing = mask == nil }
        return (mask, mask != nil)
    }

    /// 拍攝時把深度補點到接近彩色影像解析度的倍率（每軸），最多 4 倍。
    private static func densityFactor(depthWidth: Int, input: FrameInput) -> Int {
        min(4, max(1, Int((input.imageSize.x / Float(depthWidth)).rounded(.up))))
    }

    private func finishCapture(points: [PointVertex], input: FrameInput) {
        guard !points.isEmpty else {
            failCapture("範圍內沒有拍到任何點。請調整距離或「最遠距離」後重拍。")
            return
        }
        store.replace(with: points, viewDirection: input.viewDirection)
        updateStatus {
            $0.phase = .captured
            $0.captureProgress = 1
            $0.note = nil
        }
    }

    // MARK: - LiDAR / TrueDepth

    private func processDepth(_ depthBuffer: CVPixelBuffer, confidence: CVPixelBuffer?,
                              input: FrameInput, previewStep: Int) {
        guard CVPixelBufferGetPixelFormatType(depthBuffer) == kCVPixelFormatType_DepthFloat32,
              let color = YCbCrSampler(input.image) else { return }
        defer { color.unlock() }
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthBuffer) else { return }

        var depth = DepthMap(
            values: UnsafePointer(base.assumingMemoryBound(to: Float32.self)),
            rowStride: CVPixelBufferGetBytesPerRow(depthBuffer) / MemoryLayout<Float32>.stride,
            width: CVPixelBufferGetWidth(depthBuffer),
            height: CVPixelBufferGetHeight(depthBuffer))

        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer {
            if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        }
        if let confidence, let confidenceBase = CVPixelBufferGetBaseAddress(confidence),
           CVPixelBufferGetWidth(confidence) == depth.width {
            depth.confidence = UnsafePointer(confidenceBase.assumingMemoryBound(to: UInt8.self))
            depth.confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
        }
        let sourceName: String
        switch mode {
        case .lidar: sourceName = lidarCamera != nil ? "LiDAR 高解析" : "LiDAR（ARKit）"
        case .trueDepth: sourceName = "TrueDepth"
        default: sourceName = "深度"
        }
        let source = "\(sourceName) \(depth.width)×\(depth.height)"
        updateStatus {
            $0.hasReceivedDepth = true
            $0.depthSource = source
        }

        func unproject(_ map: DepthMap, step: Int) -> [PointVertex] {
            DepthUnprojector.unproject(
                depth: map, color: color, intrinsics: input.intrinsics, imageSize: input.imageSize,
                cameraTransform: input.transform, near: input.near, far: input.far, step: step)
        }

        guard input.capturing else {
            accumulator.reset()
            captureStartTransform = nil
            // 找不到物體時預覽顯示全部的點，讓使用者知道深度本身是有的
            depth.mask = objectMask(for: input).mask
            store.replace(with: unproject(depth, step: previewStep), viewDirection: input.viewDirection)
            return
        }

        if accumulator.frames == 0 { captureStartTransform = input.transform }
        accumulator.add(depth)
        let total = captureFrameCount
        let done = accumulator.frames
        updateStatus { $0.captureProgress = Float(done) / Float(total) }
        guard done >= total else { return }

        let moved = captureStartTransform.map { Self.hasMoved(from: $0, to: input.transform) } ?? false
        let averaged = accumulator.averaged()
        let width = accumulator.width
        let height = accumulator.height
        accumulator.reset()
        captureStartTransform = nil

        if moved {
            failCapture("拍攝時手機有移動。請拿穩，或靠著東西固定後重拍。")
            return
        }
        guard width == depth.width, height == depth.height else {
            failCapture("拍攝失敗，請重拍。")
            return
        }
        // 物體輪廓取自最後一幀，與下面用的顏色是同一張影像
        let object = objectMask(for: input)
        guard object.found else {
            failCapture(Self.objectMissingMessage)
            return
        }
        // 平均後的深度配上最後一幀的顏色、信心值與相機姿態，以全解析度反投影
        let points = averaged.withUnsafeBufferPointer { buffer in
            var map = DepthMap(values: buffer.baseAddress!, rowStride: width, width: width, height: height)
            map.confidence = depth.confidence
            map.confidenceStride = depth.confidenceStride
            map.mask = object.mask
            return DepthUnprojector.unprojectDense(
                depth: map, color: color, intrinsics: input.intrinsics, imageSize: input.imageSize,
                cameraTransform: input.transform, near: input.near, far: input.far,
                factor: Self.densityFactor(depthWidth: width, input: input),
                maxPoints: PointCloudStore.maxPoints)
        }
        finishCapture(points: points, input: input)
    }

    // MARK: - 特徵點

    /// ARKit 已經給世界座標，只需要過濾距離並投影回影像取顏色。
    private func processFeatures(_ features: [SIMD3<Float>], input: FrameInput) {
        guard let color = YCbCrSampler(input.image) else { return }
        defer { color.unlock() }
        let worldToCamera = input.transform.inverse
        let object = objectMask(for: input)
        if input.capturing, !object.found {
            featureFrames = 0
            failCapture(Self.objectMissingMessage)
            return
        }
        var points: [PointVertex] = []
        points.reserveCapacity(features.count)
        for point in features {
            guard let projected = DepthUnprojector.project(point, worldToCamera: worldToCamera,
                                                           intrinsics: input.intrinsics),
                  projected.depth >= input.near, projected.depth <= input.far,
                  projected.u >= 0, projected.u < input.imageSize.x,
                  projected.v >= 0, projected.v < input.imageSize.y else { continue }
            if let mask = object.mask,
               !mask.contains(x: projected.u / input.imageSize.x, y: projected.v / input.imageSize.y) {
                continue
            }
            let c = color.color(x: Int(projected.u), y: Int(projected.v))
            points.append(PointVertex(x: point.x, y: point.y, z: point.z, r: c.r, g: c.g, b: c.b))
        }
        updateStatus { $0.hasReceivedDepth = true }

        guard input.capturing else {
            featureFrames = 0
            store.replace(with: points, viewDirection: input.viewDirection)
            return
        }

        // 單幀的特徵點很少，拍攝時收集約一秒，以體素去重合併
        if featureFrames == 0 { store.clear() }
        store.append(points)
        featureFrames += 1
        let total = captureFrameCount
        let done = featureFrames
        updateStatus { $0.captureProgress = Float(done) / Float(total) }
        guard done >= total else { return }
        featureFrames = 0
        let collected = store.snapshot()
        finishCapture(points: collected, input: input)
    }

    // MARK: - ML 估計深度

    /// 模型估計相對深度 → 用這一幀的 ARKit 特徵點校正成公尺 → 反投影。
    private func processModel(featurePoints: [SIMD3<Float>], input: FrameInput) {
        if !estimatorLoaded {
            updateStatus { $0.note = "深度模型載入中…" }
            estimator = MLDepthEstimator()
            estimatorLoaded = true
            updateStatus { $0.note = nil }
        }
        guard let estimator else {
            updateStatus { $0.error = "無法載入深度模型" }
            return
        }
        guard var relative = estimator.estimate(image: input.image) else {
            if input.capturing { failCapture("深度模型推論失敗，請重拍。") }
            return
        }
        updateStatus { $0.hasReceivedDepth = true }

        let worldToCamera = input.transform.inverse
        var samples: [(relative: Float, metricDepth: Float)] = []
        samples.reserveCapacity(featurePoints.count)
        for point in featurePoints {
            guard let projected = DepthUnprojector.project(point, worldToCamera: worldToCamera,
                                                           intrinsics: input.intrinsics),
                  projected.depth > 0.05, projected.depth < 10 else { continue }
            let mx = Int(projected.u / input.imageSize.x * Float(relative.width))
            let my = Int(projected.v / input.imageSize.y * Float(relative.height))
            guard mx >= 0, mx < relative.width, my >= 0, my < relative.height else { continue }
            samples.append((relative.values[my * relative.width + mx], projected.depth))
        }

        let calibrationMessage = "無法把估計深度校正成公尺（特徵點不足）。請對準有紋理的物體，稍微移動手機後再試。"
        guard MLDepthEstimator.calibrate(&relative, samples: samples) else {
            if input.capturing {
                failCapture(calibrationMessage)
            } else {
                updateStatus { $0.note = calibrationMessage }
            }
            return
        }
        // 只清掉自己設的訊息，不要蓋掉上一次拍攝失敗的原因
        updateStatus { if $0.note == calibrationMessage { $0.note = nil } }

        let object = objectMask(for: input)
        if input.capturing, !object.found {
            failCapture(Self.objectMissingMessage)
            return
        }

        guard let color = YCbCrSampler(input.image) else { return }
        defer { color.unlock() }
        let points = relative.values.withUnsafeBufferPointer { buffer in
            var depth = DepthMap(values: buffer.baseAddress!, rowStride: relative.width,
                                 width: relative.width, height: relative.height)
            depth.mask = object.mask
            if input.capturing {
                return DepthUnprojector.unprojectDense(
                    depth: depth, color: color, intrinsics: input.intrinsics, imageSize: input.imageSize,
                    cameraTransform: input.transform, near: input.near, far: input.far,
                    factor: Self.densityFactor(depthWidth: relative.width, input: input),
                    maxPoints: PointCloudStore.maxPoints)
            }
            return DepthUnprojector.unproject(
                depth: depth, color: color, intrinsics: input.intrinsics, imageSize: input.imageSize,
                cameraTransform: input.transform, near: input.near, far: input.far, step: 3)
        }
        if input.capturing {
            finishCapture(points: points, input: input)
        } else {
            store.replace(with: points, viewDirection: input.viewDirection)
        }
    }
}

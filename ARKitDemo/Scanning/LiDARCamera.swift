import AVFoundation
import simd

/// 用 AVFoundation 的 LiDAR 深度相機取得高解析度深度。
///
/// ARKit 的 `sceneDepth` 固定只有 256×192；同一顆 LiDAR 經 AVFoundation 可以輸出到
/// 768×576（深度像素數為 9 倍），而且與彩色影像同步並附相機內參。固定視角拍攝不需要
/// ARKit 的位置追蹤，所以 LiDAR 模式優先走這條路。
nonisolated final class LiDARCamera: NSObject, AVCaptureDataOutputSynchronizerDelegate, @unchecked Sendable {
    struct Frame {
        /// 彩色影像（雙平面 YCbCr，感測器原生的橫向方向）。
        let image: CVPixelBuffer
        /// Float32 公尺深度圖。
        let depth: CVPixelBuffer
        /// 對應 `imageSize` 解析度的相機內參。
        let intrinsics: simd_float3x3
        let imageSize: SIMD2<Float>
    }

    static var isAvailable: Bool {
        AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil
    }

    /// 每組同步的影像與深度會在內部佇列上呼叫。
    var onFrame: ((Frame) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "lidar.camera")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var configured = false

    func start() {
        queue.async { [self] in
            if !configured {
                configured = configure()
            }
            if configured, !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            onError?("無法開啟 LiDAR 深度相機。請確認已允許相機權限。")
            return false
        }

        // 選深度解析度最高的格式；同樣深度下選較大的影像（不超過 1920 寬）
        var best: (format: AVCaptureDevice.Format, depth: AVCaptureDevice.Format, depthWidth: Int32, videoWidth: Int32)?
        for format in device.formats {
            let video = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard video.width <= 1920 else { continue }
            for depthFormat in format.supportedDepthDataFormats {
                let subtype = CMFormatDescriptionGetMediaSubType(depthFormat.formatDescription)
                guard subtype == kCVPixelFormatType_DepthFloat32 || subtype == kCVPixelFormatType_DepthFloat16 else {
                    continue
                }
                let depth = CMVideoFormatDescriptionGetDimensions(depthFormat.formatDescription)
                if let current = best,
                   (depth.width, video.width) <= (current.depthWidth, current.videoWidth) { continue }
                best = (format, depthFormat, depth.width, video.width)
            }
        }
        guard let best else {
            onError?("這顆相機沒有可用的深度格式。")
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // 自己指定 activeFormat 時必須用 inputPriority，否則 preset 會把格式蓋掉
        session.sessionPreset = .inputPriority
        guard session.canAddInput(input) else { return false }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        depthOutput.alwaysDiscardsLateDepthData = true
        // 系統內建的時間平滑與補洞，固定視角拍攝時有利
        depthOutput.isFilteringEnabled = true
        guard session.canAddOutput(videoOutput), session.canAddOutput(depthOutput) else { return false }
        session.addOutput(videoOutput)
        session.addOutput(depthOutput)

        do {
            try device.lockForConfiguration()
            device.activeFormat = best.format
            device.activeDepthDataFormat = best.depth
            device.unlockForConfiguration()
        } catch {
            onError?(error.localizedDescription)
            return false
        }

        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        synchronizer.setDelegate(self, queue: queue)
        self.synchronizer = synchronizer
        return true
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let depthSync = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
              !depthSync.depthDataWasDropped,
              let videoSync = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !videoSync.sampleBufferWasDropped,
              let image = CMSampleBufferGetImageBuffer(videoSync.sampleBuffer) else { return }

        let depthData = depthSync.depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        guard let calibration = depthData.cameraCalibrationData else { return }
        let reference = calibration.intrinsicMatrixReferenceDimensions
        onFrame?(Frame(
            image: image,
            depth: depthData.depthDataMap,
            intrinsics: calibration.intrinsicMatrix,
            imageSize: SIMD2(Float(reference.width), Float(reference.height))))
    }
}

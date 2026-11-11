import ARKit
import MetalKit
import simd

enum PointColorMode: UInt32 {
    case real = 0
    case height = 1
}

/// 不經 ARKit 取得的相機影格（AVFoundation 的 LiDAR 深度相機），供掃描畫面當背景並對齊點。
nonisolated struct PreviewFrame {
    /// 雙平面 YCbCr 影像，感測器原生的橫向方向。
    let image: CVPixelBuffer
    /// 對應 `imageSize` 的相機內參。
    let intrinsics: simd_float3x3
    let imageSize: SIMD2<Float>
    /// 相機 → 點雲座標系的變換。
    let cameraTransform: simd_float4x4
}

/// 以 Metal 繪製 `PointCloudStore`。
/// - 有 `arSession` 時：畫相機背景，並用 ARKit 的相機矩陣把點疊在畫面上（掃描畫面）。
/// - 沒有時：用軌道相機繞著點雲看（檢視器）。
final class PointCloudRenderer: NSObject, MTKViewDelegate {
    private struct PointUniforms {
        var mvp: simd_float4x4
        var pointSize: Float
        var yMin: Float
        var yMax: Float
        var colorMode: UInt32
    }

    private struct BackgroundUniforms {
        var uv: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
    }

    let store: PointCloudStore
    let arSession: ARSession?
    /// 非 ARKit 的影格來源；與 `arSession` 擇一。
    let previewFrame: (() -> PreviewFrame?)?
    /// 是否為疊在相機畫面上的掃描預覽（否則是軌道相機檢視器）。
    private var isOverlay: Bool { arSession != nil || previewFrame != nil }

    var colorMode: PointColorMode = .real
    /// 以 point 為單位，繪製時乘上螢幕 scale。
    var pointSize: Float = 3

    // 軌道相機
    private var yaw: Float = 0.6
    private var pitch: Float = 0.3
    private var distance: Float = 1
    private var target = SIMD3<Float>(repeating: 0)
    private var fittedGeneration = -1
    private var hasFitted = false
    private let fovY: Float = .pi / 3
    private var aspect: Float = 1

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pointPipeline: MTLRenderPipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let pointDepthState: MTLDepthStencilState
    private let backgroundDepthState: MTLDepthStencilState
    private var textureCache: CVMetalTextureCache?

    private var pointBuffer: MTLBuffer?
    private var uploadedCount = 0
    private var uploadedGeneration = -1

    init?(view: MTKView, store: PointCloudStore, arSession: ARSession?,
          previewFrame: (() -> PreviewFrame?)? = nil) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSource.metal, options: nil)
        } catch {
            print("Shader 編譯失敗：\(error)")
            return nil
        }
        self.device = device
        self.commandQueue = queue
        self.store = store
        self.arSession = arSession
        self.previewFrame = previewFrame

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .uchar4Normalized
        vertexDescriptor.attributes[1].offset = 12
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<PointVertex>.stride

        let pointDescriptor = MTLRenderPipelineDescriptor()
        pointDescriptor.vertexFunction = library.makeFunction(name: "pointVertex")
        pointDescriptor.fragmentFunction = library.makeFunction(name: "pointFragment")
        pointDescriptor.vertexDescriptor = vertexDescriptor
        pointDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pointDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        let backgroundDescriptor = MTLRenderPipelineDescriptor()
        backgroundDescriptor.vertexFunction = library.makeFunction(name: "backgroundVertex")
        backgroundDescriptor.fragmentFunction = library.makeFunction(name: "backgroundFragment")
        backgroundDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        backgroundDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        let pointDepth = MTLDepthStencilDescriptor()
        pointDepth.depthCompareFunction = .less
        pointDepth.isDepthWriteEnabled = true
        let backgroundDepth = MTLDepthStencilDescriptor()
        backgroundDepth.depthCompareFunction = .always
        backgroundDepth.isDepthWriteEnabled = false

        let pointPipeline: MTLRenderPipelineState
        let backgroundPipeline: MTLRenderPipelineState
        do {
            pointPipeline = try device.makeRenderPipelineState(descriptor: pointDescriptor)
            backgroundPipeline = try device.makeRenderPipelineState(descriptor: backgroundDescriptor)
        } catch {
            print("Render pipeline 建立失敗：\(error)")
            return nil
        }
        guard let pointDepthState = device.makeDepthStencilState(descriptor: pointDepth),
              let backgroundDepthState = device.makeDepthStencilState(descriptor: backgroundDepth) else { return nil }
        self.pointPipeline = pointPipeline
        self.backgroundPipeline = backgroundPipeline
        self.pointDepthState = pointDepthState
        self.backgroundDepthState = backgroundDepthState

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        super.init()
    }

    // MARK: - 軌道相機操作

    func rotate(dx: Float, dy: Float) {
        yaw -= dx * 0.01
        pitch = min(max(pitch + dy * 0.01, -1.55), 1.55)
    }

    func zoom(scale: Float) {
        guard scale > 0 else { return }
        distance = min(max(distance / scale, 0.01), 100)
    }

    /// 沿著畫面的右方與上方移動注視點。
    func pan(dx: Float, dy: Float, viewHeight: Float) {
        let (right, up, _) = cameraBasis()
        let metersPerPoint = 2 * distance * tan(fovY / 2) / max(viewHeight, 1)
        target += (-dx * right + dy * up) * metersPerPoint
    }

    func resetCamera() {
        if let direction = store.preferredViewDirection {
            // 從拍攝方向稍微偏一點看過去，立體感比較明顯
            yaw = atan2(direction.x, direction.z) + 0.35
            pitch = min(max(asin(min(max(direction.y, -1), 1)) + 0.15, -1.55), 1.55)
        } else {
            yaw = 0.6
            pitch = 0.3
        }
        fitToBounds()
    }

    private func fitToBounds() {
        guard let bounds = store.bounds else { return }
        target = (bounds.min + bounds.max) / 2
        let radius = max(simd_length(bounds.max - bounds.min) / 2, 0.01)
        // 直向畫面時水平視角較窄，以較窄的那個方向為準才不會被裁掉
        let fovX = 2 * atan(tan(fovY / 2) * aspect)
        distance = radius / sin(min(fovY, fovX) / 2) * 1.1
        hasFitted = true
    }

    private func cameraBasis() -> (right: SIMD3<Float>, up: SIMD3<Float>, back: SIMD3<Float>) {
        let back = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up = simd_cross(back, right)
        return (right, up, back)
    }

    private func orbitViewProjection(aspect: Float) -> simd_float4x4 {
        let (right, up, back) = cameraBasis()
        let eye = target + back * distance
        let view = simd_float4x4(columns: (
            SIMD4(right.x, up.x, back.x, 0),
            SIMD4(right.y, up.y, back.y, 0),
            SIMD4(right.z, up.z, back.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), -simd_dot(back, eye), 1)))
        let near = distance * 0.01
        let far = distance * 100
        let ys = 1 / tan(fovY / 2)
        let xs = ys / aspect
        let zs = far / (near - far)
        let projection = simd_float4x4(columns: (
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, zs, -1),
            SIMD4(0, 0, zs * near, 0)))
        return projection * view
    }

    // MARK: - GPU buffer

    /// 只上傳上次之後新增的點；store 被清除（generation 改變）時從頭來。
    private func syncPointBuffer() {
        let stride = MemoryLayout<PointVertex>.stride
        if pointBuffer == nil {
            pointBuffer = device.makeBuffer(length: PointCloudStore.maxPoints * stride, options: .storageModeShared)
        }
        guard let buffer = pointBuffer else { return }
        let state = store.state
        if state.generation != uploadedGeneration {
            uploadedGeneration = state.generation
            uploadedCount = 0
        }
        if state.count > uploadedCount {
            let destination = buffer.contents() + uploadedCount * stride
            uploadedCount += store.copyPoints(from: uploadedCount, to: destination,
                                              maxCount: PointCloudStore.maxPoints - uploadedCount)
        }
        if !isOverlay, uploadedCount > 0, !hasFitted || fittedGeneration != state.generation {
            fittedGeneration = state.generation
            resetCamera()
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let size = view.drawableSize
        aspect = Float(size.width / size.height)
        syncPointBuffer()

        var viewProjection: simd_float4x4?

        let orientation = view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        if let session = arSession {
            if let frame = session.currentFrame {
                viewProjection = drawBackground(frame: frame, orientation: orientation, size: size,
                                                encoder: encoder, commandBuffer: commandBuffer)
            }
        } else if let previewFrame {
            if let frame = previewFrame() {
                let display = Self.displayTransform(imageSize: frame.imageSize, orientation: orientation,
                                                    viewport: size)
                drawCameraImage(frame.image, display: display, encoder: encoder, commandBuffer: commandBuffer)
                viewProjection = Self.projection(intrinsics: frame.intrinsics, imageSize: frame.imageSize,
                                                 display: display) * frame.cameraTransform.inverse
            }
        } else {
            viewProjection = orbitViewProjection(aspect: Float(size.width / size.height))
        }

        if let viewProjection, uploadedCount > 0, let buffer = pointBuffer {
            let bounds = store.bounds
            var uniforms = PointUniforms(
                mvp: viewProjection,
                pointSize: pointSize * Float(view.contentScaleFactor),
                yMin: bounds?.min.y ?? 0,
                yMax: bounds?.max.y ?? 1,
                colorMode: colorMode.rawValue)
            encoder.setRenderPipelineState(pointPipeline)
            encoder.setDepthStencilState(pointDepthState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<PointUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: uploadedCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// 畫相機影像，回傳讓點對齊這張影像的 view-projection 矩陣。
    private func drawBackground(frame: ARFrame, orientation: UIInterfaceOrientation, size: CGSize,
                                encoder: MTLRenderCommandEncoder,
                                commandBuffer: MTLCommandBuffer) -> simd_float4x4 {
        let display = frame.displayTransform(for: orientation, viewportSize: size)
        drawCameraImage(frame.capturedImage, display: display, encoder: encoder, commandBuffer: commandBuffer)

        var projection = frame.camera.projectionMatrix(for: orientation, viewportSize: size, zNear: 0.01, zFar: 50)
        // 前鏡頭的畫面是鏡像顯示。確保點的投影與背景的鏡像狀態一致，否則疊加會左右相反。
        let displayMirrored = display.a * display.d - display.b * display.c < 0
        let projectionMirrored = projection[0][0] * projection[1][1] - projection[0][1] * projection[1][0] < 0
        if displayMirrored != projectionMirrored {
            projection = simd_float4x4(diagonal: SIMD4(-1, 1, 1, 1)) * projection
        }
        return projection * frame.camera.viewMatrix(for: orientation)
    }

    /// 影像正規化座標 → 畫面正規化座標（兩者皆以左上為原點）：依介面方向旋轉，再以填滿方式裁切。
    /// 後鏡頭的影像原生方向是橫向（Home 鍵在右）。
    private static func displayTransform(imageSize: SIMD2<Float>, orientation: UIInterfaceOrientation,
                                         viewport: CGSize) -> CGAffineTransform {
        let rotation: CGAffineTransform
        var rotatedAspect = CGFloat(imageSize.x / imageSize.y)
        switch orientation {
        case .landscapeRight:
            rotation = .identity
        case .landscapeLeft:
            rotation = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        case .portraitUpsideDown:
            rotation = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
            rotatedAspect = 1 / rotatedAspect
        default:
            rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
            rotatedAspect = 1 / rotatedAspect
        }
        let viewAspect = viewport.width / viewport.height
        let scaleX = max(rotatedAspect / viewAspect, 1)
        let scaleY = max(viewAspect / rotatedAspect, 1)
        let fill = CGAffineTransform(translationX: -0.5, y: -0.5)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(CGAffineTransform(translationX: 0.5, y: 0.5))
        return rotation.concatenating(fill)
    }

    /// 由相機內參與顯示變換組出投影矩陣，讓相機座標的點落在背景影像對應的像素上。
    private static func projection(intrinsics: simd_float3x3, imageSize: SIMD2<Float>,
                                   display: CGAffineTransform) -> simd_float4x4 {
        // 以下各列都是「乘上深度 d = -z 之後」的量，對 (x, y, z, 1) 為線性
        let u = SIMD4<Float>(intrinsics[0][0] / imageSize.x, 0, -intrinsics[2][0] / imageSize.x, 0)
        let v = SIMD4<Float>(0, -intrinsics[1][1] / imageSize.y, -intrinsics[2][1] / imageSize.y, 0)
        let d = SIMD4<Float>(0, 0, -1, 0)
        let screenX = Float(display.a) * u + Float(display.c) * v + Float(display.tx) * d
        let screenY = Float(display.b) * u + Float(display.d) * v + Float(display.ty) * d
        let near: Float = 0.01
        let far: Float = 50
        return simd_float4x4(rows: [
            2 * screenX - d,
            d - 2 * screenY,
            SIMD4(0, 0, -far / (far - near), -far * near / (far - near)),
            d,
        ])
    }

    private func drawCameraImage(_ image: CVPixelBuffer, display: CGAffineTransform,
                                 encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer) {
        if CVPixelBufferGetPlaneCount(image) >= 2,
           let luma = makeTexture(image, plane: 0, format: .r8Unorm),
           let chroma = makeTexture(image, plane: 1, format: .rg8Unorm),
           let lumaTexture = CVMetalTextureGetTexture(luma),
           let chromaTexture = CVMetalTextureGetTexture(chroma) {
            // 畫面座標（左上為原點）→ 影像座標
            let inverse = display.inverted()
            func uv(_ x: CGFloat, _ y: CGFloat) -> SIMD2<Float> {
                let p = CGPoint(x: x, y: y).applying(inverse)
                return SIMD2(Float(p.x), Float(p.y))
            }
            var uniforms = BackgroundUniforms(uv: (uv(0, 1), uv(1, 1), uv(0, 0), uv(1, 0)))
            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.setDepthStencilState(backgroundDepthState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<BackgroundUniforms>.stride, index: 0)
            encoder.setFragmentTexture(lumaTexture, index: 0)
            encoder.setFragmentTexture(chromaTexture, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            // CVMetalTexture 必須活到 GPU 用完為止
            commandBuffer.addCompletedHandler { _ in
                _ = luma
                _ = chroma
            }
        }
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, format,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, plane),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, plane),
            plane, &texture)
        return texture
    }
}

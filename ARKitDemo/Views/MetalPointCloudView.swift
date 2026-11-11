import ARKit
import MetalKit
import SwiftUI

/// SwiftUI 包裝的 Metal 點雲畫面。
/// `session` 為 nil 時是可用手勢操作的檢視器；有值時是疊在相機畫面上的掃描預覽。
struct MetalPointCloudView: UIViewRepresentable {
    let store: PointCloudStore
    var session: ARSession? = nil
    /// 非 ARKit 的相機影格來源（LiDAR 高解析模式）。
    var previewFrame: (() -> PreviewFrame?)? = nil
    var colorMode: PointColorMode = .real
    var pointSize: Float = 3

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        let renderer = PointCloudRenderer(view: view, store: store, arSession: session, previewFrame: previewFrame)
        context.coordinator.renderer = renderer
        view.delegate = renderer

        if session == nil, previewFrame == nil {
            let coordinator = context.coordinator
            let rotate = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleRotate))
            rotate.maximumNumberOfTouches = 1
            let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch))
            let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            for recognizer in [rotate, pan, pinch, doubleTap] {
                recognizer.delegate = coordinator
                view.addGestureRecognizer(recognizer)
            }
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.colorMode = colorMode
        context.coordinator.renderer?.pointSize = pointSize
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: PointCloudRenderer?

        @objc func handleRotate(_ recognizer: UIPanGestureRecognizer) {
            let delta = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            renderer?.rotate(dx: Float(delta.x), dy: Float(delta.y))
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let delta = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            renderer?.pan(dx: Float(delta.x), dy: Float(delta.y),
                          viewHeight: Float(recognizer.view?.bounds.height ?? 1))
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            renderer?.zoom(scale: Float(recognizer.scale))
            recognizer.scale = 1
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            renderer?.resetCamera()
        }

        /// 讓雙指平移與捏合縮放可以同時進行。
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

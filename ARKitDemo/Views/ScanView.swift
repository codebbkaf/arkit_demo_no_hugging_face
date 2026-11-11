import Combine
import SwiftUI

/// 掃描畫面的狀態。引擎在背景執行緒工作，這裡定時把它的狀態拉回主執行緒。
@Observable
final class ScanViewModel {
    let mode: ScanMode
    let store = PointCloudStore()
    let engine: ScanEngine

    var status = ScanStatus()
    var maxDistance: Float {
        didSet { engine.setMaxDistance(maxDistance) }
    }
    /// 只保留準星對到的物體，去掉桌面與背景。
    var isolateObject = true {
        didSet { engine.setIsolateObject(isolateObject) }
    }
    /// 執行超過數秒仍沒有收到任何深度資料。
    var depthMissing = false
    /// 拍攝剛完成，畫面應該切到檢視器。
    var showViewer = false

    private var runningSince: Date?
    private var lastPhase: ScanPhase = .preview
    private let haptics = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()

    init(mode: ScanMode) {
        self.mode = mode
        self.maxDistance = mode.defaultFar
        self.engine = ScanEngine(mode: mode, store: store)
    }

    func appear() {
        engine.run()
        runningSince = Date()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func disappear() {
        engine.pause()
        runningSince = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func capture() {
        haptics.impactOccurred()
        engine.capture()
    }

    func retake() {
        engine.retake()
    }

    func refresh() {
        status = engine.status()

        if status.phase != lastPhase {
            switch (lastPhase, status.phase) {
            case (.capturing, .captured):
                notification.notificationOccurred(.success)
                showViewer = true
            case (.capturing, .preview):
                notification.notificationOccurred(.error)
            default:
                break
            }
            lastPhase = status.phase
        }

        if let since = runningSince, !status.hasReceivedDepth, status.trackingMessage == nil {
            depthMissing = Date().timeIntervalSince(since) > 4
        } else {
            depthMissing = false
        }
    }
}

struct ScanView: View {
    @State private var model: ScanViewModel
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    init(mode: ScanMode) {
        _model = State(initialValue: ScanViewModel(mode: mode))
    }

    var body: some View {
        ZStack {
            MetalPointCloudView(
                store: model.store,
                session: model.engine.usesARSession ? model.engine.session : nil,
                previewFrame: model.engine.usesARSession ? nil : { [engine = model.engine] in engine.previewFrame() },
                pointSize: 2)
                .ignoresSafeArea()

            if model.isolateObject, model.status.phase != .captured {
                // 準星：物體隔離會選畫面正中央對到的物體
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(model.status.objectMissing ? .orange : .white)
                    .shadow(radius: 3)
                    .ignoresSafeArea()
                    .accessibilityLabel("準星")
            }

            VStack(spacing: 12) {
                banner
                Spacer()
                Text("\(model.status.pointCount.formatted()) 個點")
                    .font(.title2.bold())
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                if let source = model.status.depthSource {
                    Text("深度來源：\(source)")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
                controls
            }
            .padding()
        }
        .navigationTitle(model.mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationDestination(isPresented: $model.showViewer) {
            ViewerView(store: model.store)
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .onReceive(timer) { _ in model.refresh() }
    }

    /// 畫面上方的提示：錯誤 > 追蹤問題 > 沒有深度 > 補充訊息 > 操作說明。
    @ViewBuilder
    private var banner: some View {
        let message: (text: String, isWarning: Bool) = {
            if let error = model.status.error { return (error, true) }
            if let tracking = model.status.trackingMessage { return (tracking, true) }
            if model.depthMissing {
                return ("沒有收到深度資料。請確認鏡頭沒有被遮住，並讓物體在有效距離內。", true)
            }
            if let note = model.status.note { return (note, true) }
            if model.status.objectMissing, model.status.phase == .preview {
                return ("準星附近找不到物體，目前顯示全部的點。請把準星對準要掃描的物體。", true)
            }
            switch model.status.phase {
            case .preview: return (model.mode.hint, false)
            case .capturing: return ("拍攝中，請保持不動…", false)
            case .captured: return ("已拍攝。可以檢視模型，或重拍。", false)
            }
        }()
        Text(message.text)
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(message.isWarning ? AnyShapeStyle(.orange.opacity(0.9)) : AnyShapeStyle(.regularMaterial),
                        in: RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if model.status.phase != .captured {
                HStack {
                    Text("最遠距離")
                    Slider(value: $model.maxDistance, in: model.mode.farRange)
                    Text(String(format: "%.2f m", model.maxDistance))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                .font(.subheadline)
                .disabled(model.status.phase == .capturing)

                Toggle("只保留準星對到的物體", isOn: $model.isolateObject)
                    .font(.subheadline)
                    .disabled(model.status.phase == .capturing)
            }

            switch model.status.phase {
            case .preview:
                Button {
                    model.capture()
                } label: {
                    Label("拍攝", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.status.error != nil || model.status.trackingMessage != nil
                          || !model.status.hasReceivedDepth)
            case .capturing:
                ProgressView(value: model.status.captureProgress)
                    .padding(.vertical, 12)
            case .captured:
                HStack(spacing: 12) {
                    Button {
                        model.retake()
                    } label: {
                        Label("重拍", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.showViewer = true
                    } label: {
                        Label("檢視模型", systemImage: "cube.transparent")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .controlSize(.large)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

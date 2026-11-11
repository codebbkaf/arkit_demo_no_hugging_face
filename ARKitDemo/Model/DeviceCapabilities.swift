import ARKit
import Foundation

/// 四種掃描模式。
nonisolated enum ScanMode: String, CaseIterable, Identifiable, Hashable {
    case lidar
    case trueDepth
    case featurePoints
    case mlDepth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lidar: "LiDAR 深度掃描"
        case .trueDepth: "TrueDepth 深度掃描"
        case .featurePoints: "特徵點掃描"
        case .mlDepth: "ML 估計深度掃描（實驗性）"
        }
    }

    var icon: String {
        switch self {
        case .lidar: "dot.radiowaves.left.and.right"
        case .trueDepth: "faceid"
        case .featurePoints: "sparkles"
        case .mlDepth: "brain"
        }
    }

    var sensor: String {
        switch self {
        case .lidar: "後置 LiDAR"
        case .trueDepth: "前置 TrueDepth（Face ID 鏡頭）"
        case .featurePoints: "後置相機"
        case .mlDepth: "後置相機 + 深度模型"
        }
    }

    var accuracy: String {
        switch self {
        case .lidar: "公分級，量測深度（最高 768×576）"
        case .trueDepth: "公釐級，量測深度"
        case .featurePoints: "稀疏，僅輪廓"
        case .mlDepth: "密集，但深度為模型估計值"
        }
    }

    var bestFor: String {
        switch self {
        case .lidar: "中大型物體、家具，距離 0.3–3 m"
        case .trueDepth: "小物體的表面凹凸，距離 15–50 cm"
        case .featurePoints: "有紋理的物體，看大致形狀"
        case .mlDepth: "沒有深度感測器時取得密集點雲"
        }
    }

    var hint: String {
        switch self {
        case .lidar: "把準星對準物體，拿穩後按「拍攝」。"
        case .trueDepth: "前鏡頭（螢幕這一面）對著物體，距離 15–50 cm，讓物體在準星上，拿穩後按「拍攝」。"
        case .featurePoints: "先稍微移動手機讓畫面出現特徵點，再拿穩按「拍攝」。只會得到稀疏的輪廓點。"
        case .mlDepth: "先稍微移動手機讓預覽出現點，再拿穩按「拍攝」。深度是模型估計值，僅供參考。"
        }
    }

    /// 保留點的最近距離（公尺）。
    var nearDistance: Float {
        switch self {
        case .lidar: 0.2
        case .trueDepth: 0.15
        case .featurePoints, .mlDepth: 0.1
        }
    }

    /// 最遠距離滑桿的範圍與預設值（公尺）。
    var farRange: ClosedRange<Float> {
        switch self {
        case .trueDepth: 0.2...1.0
        default: 0.5...3.0
        }
    }

    var defaultFar: Float {
        self == .trueDepth ? 0.6 : 1.5
    }
}

/// 啟動時偵測一次的硬體能力。
nonisolated struct DeviceCapabilities {
    let modelIdentifier: String
    let modelName: String
    let hasWorldTracking: Bool
    let hasLiDAR: Bool
    let hasTrueDepth: Bool
    let hasDepthModel: Bool

    static let current = DeviceCapabilities()

    private init() {
        let identifier = Self.readModelIdentifier()
        modelIdentifier = identifier
        modelName = Self.modelNames[identifier] ?? identifier
        hasWorldTracking = ARWorldTrackingConfiguration.isSupported
        hasLiDAR = ARWorldTrackingConfiguration.isSupported
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        hasTrueDepth = ARFaceTrackingConfiguration.isSupported
        hasDepthModel = MLDepthEstimator.modelURL != nil
    }

    /// nil 表示可用；否則為不可用的原因。
    func unavailableReason(for mode: ScanMode) -> String? {
        switch mode {
        case .lidar:
            if !hasWorldTracking { return "此裝置不支援 ARKit world tracking" }
            return hasLiDAR ? nil : "此裝置沒有 LiDAR（僅 Pro 機型具備）"
        case .trueDepth:
            return hasTrueDepth ? nil : "此裝置沒有 TrueDepth 前鏡頭"
        case .featurePoints:
            return hasWorldTracking ? nil : "此裝置不支援 ARKit world tracking"
        case .mlDepth:
            if !hasWorldTracking { return "此裝置不支援 ARKit world tracking" }
            return hasDepthModel ? nil : "App 內找不到深度模型檔（此版本未內建，見 README）"
        }
    }

    private static func readModelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// 只列近幾代 iPhone；查不到時直接顯示識別碼。
    private static let modelNames: [String: String] = [
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
    ]
}

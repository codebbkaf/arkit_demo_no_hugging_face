import SwiftUI

/// 首頁：顯示偵測到的硬體，以及每種掃描模式在這支裝置上能不能用、能做到什麼。
struct HomeView: View {
    private let capabilities = DeviceCapabilities.current
    @State private var demoStore: PointCloudStore?

    var body: some View {
        List {
            Section("這支裝置") {
                LabeledContent("型號", value: capabilities.modelName)
                HardwareRow(name: "LiDAR（後置深度感測器）", available: capabilities.hasLiDAR)
                HardwareRow(name: "TrueDepth（前置深度鏡頭）", available: capabilities.hasTrueDepth)
                HardwareRow(name: "ARKit 空間追蹤", available: capabilities.hasWorldTracking)
            }

            Section {
                ForEach(ScanMode.allCases) { mode in
                    let reason = capabilities.unavailableReason(for: mode)
                    NavigationLink(value: mode) {
                        ModeCard(mode: mode, unavailableReason: reason)
                    }
                    .disabled(reason != nil)
                }
            } header: {
                Text("選擇掃描方式")
            } footer: {
                Text("手機固定在一個角度拍一次，把看得到的那一面轉成 x y z 點雲。")
            }

            Section {
                Button("開啟示範點雲") {
                    demoStore = PointCloudStore.demo()
                }
            } footer: {
                Text("不需要相機，用內建的示範模型試用 3D 檢視器。")
            }
        }
        .navigationTitle("3D 點雲掃描")
        .navigationDestination(for: ScanMode.self) { mode in
            ScanView(mode: mode)
        }
        .navigationDestination(item: $demoStore) { store in
            ViewerView(store: store)
        }
        #if DEBUG
        // 以 `-demoViewer` 啟動時直接開啟示範點雲，方便在模擬器截圖檢查檢視器
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-demoViewer"), demoStore == nil {
                demoStore = PointCloudStore.demo()
            }
        }
        #endif
    }
}

private struct HardwareRow: View {
    let name: String
    let available: Bool

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Label(available ? "可用" : "不可用",
                  systemImage: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(available ? .green : .secondary)
                .font(.subheadline)
        }
    }
}

private struct ModeCard: View {
    let mode: ScanMode
    let unavailableReason: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: mode.icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(unavailableReason == nil ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title)
                    .font(.headline)
                if let unavailableReason {
                    Label(unavailableReason, systemImage: "nosign")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Group {
                        Text("感測器：\(mode.sensor)")
                        Text("精度：\(mode.accuracy)")
                        Text("適合：\(mode.bestFor)")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

extension PointCloudStore: Identifiable, Hashable {
    nonisolated static func == (lhs: PointCloudStore, rhs: PointCloudStore) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

#Preview {
    NavigationStack { HomeView() }
}

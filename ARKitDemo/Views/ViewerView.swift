import SwiftUI

/// 3D 檢視器：旋轉、縮放、平移點雲，查看座標統計並匯出 PLY。
struct ViewerView: View {
    let store: PointCloudStore

    @State private var colorMode: PointColorMode = .real
    @State private var pointSize: Float = 3
    @State private var isExporting = false
    @State private var exportedFile: ExportedFile?
    @State private var exportError: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            MetalPointCloudView(store: store, colorMode: colorMode, pointSize: pointSize)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                stats
                Picker("顏色", selection: $colorMode) {
                    Text("真實色").tag(PointColorMode.real)
                    Text("高度色").tag(PointColorMode.height)
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("點大小")
                    Slider(value: $pointSize, in: 1...12)
                }
                .font(.subheadline)

                Text("單指旋轉・雙指平移・捏合縮放・點兩下重置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
        .background(.black)
        .navigationTitle("點雲模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isExporting {
                    ProgressView()
                } else {
                    Button("匯出 PLY", systemImage: "square.and.arrow.up", action: export)
                        .disabled(store.count == 0)
                }
            }
        }
        .sheet(item: $exportedFile) { file in
            ActivityView(items: [file.url])
        }
        .alert("匯出失敗", isPresented: .constant(exportError != nil)) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var stats: some View {
        let count = store.count
        let size = store.bounds.map { ($0.max - $0.min) * 100 }
        return VStack(spacing: 4) {
            Text("\(count.formatted()) 個點")
                .font(.headline)
            if let size {
                Text(String(format: "寬 %.1f × 高 %.1f × 深 %.1f cm", size.x, size.y, size.z))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func export() {
        isExporting = true
        let store = store
        Task.detached(priority: .userInitiated) {
            let result = Result { try PLYExporter.write(store.snapshot()) }
            await MainActor.run {
                isExporting = false
                switch result {
                case .success(let url): exportedFile = ExportedFile(url: url)
                case .failure(let error): exportError = error.localizedDescription
                }
            }
        }
    }
}

private struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

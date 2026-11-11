# ARKitDemo：3D 點雲掃描

把真實世界的物體從固定角度拍一次，轉成 x y z 座標的點雲，並在 App 內旋轉、縮放、把玩。

## 功能

- **硬體偵測**：首頁顯示裝置型號與 LiDAR、TrueDepth、ARKit 空間追蹤是否可用，不支援的掃描模式會停用並說明原因。
- **四種掃描模式**
  | 模式 | 深度來源 | 特性 |
  |---|---|---|
  | LiDAR 深度掃描 | 後置 LiDAR（AVFoundation，最高 768×576；不可用時退回 ARKit `sceneDepth` 256×192） | 公分級，適合 30 cm 以上的物體 |
  | TrueDepth 深度掃描 | 前置 TrueDepth（ARKit `capturedDepthData`，640×480） | 公釐級，適合 15–50 cm 的小物體表面凹凸 |
  | 特徵點掃描 | ARKit `rawFeaturePoints` | 稀疏，只有輪廓 |
  | ML 估計深度掃描（實驗性，此版本停用） | 後置相機 + Depth Anything V2 Small，以 ARKit 特徵點校正成公尺 | 需另外放入模型檔 |
- **只掃描一個物體**：以 Vision 前景主體分割取出畫面中央準星對到的物體，桌面與背景不會轉成點。
- **固定視角單次拍攝**：多幀深度逐像素平均降低雜訊，並在相鄰量測值之間內插補點提高密度；拍攝時手機晃動會提示重拍。
- **3D 檢視器**：Metal 繪製，單指旋轉、雙指平移、捏合縮放、點兩下重置；可切換真實色／高度色與點大小。
- **匯出**：顯示點數與邊界尺寸，可匯出 binary PLY（x y z 公尺 + RGB），能在 MeshLab、CloudCompare、Blender 開啟。

所有運算都在裝置上進行，不需要網路。

## 需求與編譯

- Xcode 27.1、iOS 27.0 以上
- ARKit 無法在模擬器執行，掃描功能需要實機；模擬器上可用首頁的「開啟示範點雲」試用檢視器

```sh
scripts/build.sh device   # 對實機編譯（不簽章）
scripts/build.sh sim      # 對模擬器編譯
```

腳本以 `DEVELOPER_DIR` 指定 `/Applications/Xcode_27_1.app`，Xcode 裝在其他位置時請自行修改。
Metal shader 以字串形式在執行時編譯（`ARKitDemo/Rendering/ShaderSource.swift`），不需要另外安裝 Metal Toolchain。

## 專案結構

```
ARKitDemo/
  Model/       點雲儲存、PLY 匯出、硬體偵測與掃描模式定義
  Scanning/    掃描引擎、深度反投影、LiDAR 相機、物體分割、ML 深度估計
  Rendering/   Metal 點雲 renderer 與 shader
  Views/       首頁、掃描畫面、檢視器
tasks/         PRD
prd.json       Ralph 格式的 user stories 與驗證狀態
```

## 關於這個版本

這個 repo **不含深度模型檔**，編譯與執行都不需要連到 Hugging Face 或任何外部網路。

- LiDAR、TrueDepth、特徵點三種模式完全不受影響。
- 「ML 估計深度掃描」會在首頁顯示為停用，原因為「App 內找不到深度模型檔」。
- 若之後能取得 Apple 發佈的 Depth Anything V2 Small Core ML 模型，把 `DepthAnythingV2SmallF16.mlpackage`
  整個資料夾放到 `ARKitDemo/` 底下重新編譯，ML 模式就會自動啟用，不需要改程式。

## 參考專案

開發時在 GitHub 上找到的功能相近的開源專案。以下說明依據各 repo 的簡介整理。

### 功能相近

- [TokyoYoshida/ExampleOfiOSLiDAR](https://github.com/TokyoYoshida/ExampleOfiOSLiDAR)：ARKit LiDAR 的各種範例集。
- [marek-simonik/record3d](https://github.com/marek-simonik/record3d)：Record3D App 的配套函式庫，串流 iPhone 的彩色與深度資料。
- [StandardCyborg/StandardCyborgSDK](https://github.com/StandardCyborg/StandardCyborgSDK)：以 TrueDepth 做 3D 掃描與網格重建的 SDK。
- [Dominik-Hagmann/lidar-scanner-ios](https://github.com/Dominik-Hagmann/lidar-scanner-ios)：開源的 LiDAR 點雲掃描與匯出 App。
- [CurvSurf/ARKitPointCloudRecorder](https://github.com/CurvSurf/ARKitPointCloudRecorder)：錄製並過濾 ARKit 點雲的示範 App。
- [lxk121lalala/RGBD_data_capture](https://github.com/lxk121lalala/RGBD_data_capture)：以 TrueDepth 擷取彩色與深度資料。
- [montaguegabe/arkit-depth-renderer](https://github.com/montaguegabe/arkit-depth-renderer)：顯示前鏡頭經 ARKit 取得的深度值。

### 延伸方向

- [nghiaho12/Open3D_TrueDepth_registration](https://github.com/nghiaho12/Open3D_TrueDepth_registration)：以 Open3D 自動對齊多張 TrueDepth 點雲，可參考多角度拼接的做法。
- [neycyanshi/InfiniTAM_ios](https://github.com/neycyanshi/InfiniTAM_ios)：以 TrueDepth 做即時臉部與身體 3D 重建。
- [StandardCyborg/mirror-clip](https://github.com/StandardCyborg/mirror-clip)：可 3D 列印的鏡子夾，讓前置 TrueDepth 朝外掃描，解決掃描時看不到螢幕的問題。
- [a1091150/ScanApp](https://github.com/a1091150/ScanApp)：ARKit LiDAR 掃描與匯出的小型範例。

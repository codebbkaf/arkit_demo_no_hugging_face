# PRD: ARKit 點雲掃描器

## Introduction

用 ARKit 把真實世界物體的形狀與表面凹凸掃描成 x y z 座標點雲，並在 app 內以 3D 方式繪製，讓使用者旋轉、縮放、把玩。App 啟動時偵測裝置硬體，列出這支裝置可用的掃描模式與各自的能力，由使用者選擇。

主要測試裝置為 iPhone 17（無 LiDAR，有前置 TrueDepth）。

## Goals

- 偵測裝置型號與感測器，清楚告知每種掃描模式能做到什麼
- 提供四種掃描模式：LiDAR、TrueDepth、後置特徵點、後置 ML 估計深度
- 把深度資料轉成世界座標 x y z（公尺）並跨幀累積成單一點雲
- 以 Metal 繪製點雲，百萬點仍可流暢互動
- 可匯出 `.ply`，讓座標能在其他軟體使用

## User Stories

### US-001: 專案基礎設定
**Description:** 身為開發者，我需要版本控制、相機權限與可重複的編譯指令，後續 story 才能逐一驗證。

**Acceptance Criteria:**
- [ ] `git init`，加入 `.gitignore`（xcuserdata、DerivedData、build）
- [ ] build settings 加入 `INFOPLIST_KEY_NSCameraUsageDescription`（繁體中文說明）
- [ ] `scripts/build.sh` 以 `DEVELOPER_DIR=/Applications/Xcode_27_1.app/Contents/Developer` 對 generic iOS device 編譯（不簽章）
- [ ] 編譯通過

### US-002: 點雲資料模型、體素去重與 PLY 編碼
**Description:** 身為開發者，我需要一個與感測器無關的點雲儲存結構，所有掃描模式都寫入同一個地方。

**Acceptance Criteria:**
- [ ] `PointCloudPoint`：`position: SIMD3<Float>`（公尺，ARKit 世界座標）＋ RGB 顏色
- [ ] `PointCloudStore`：以體素格（預設 3 mm）去重，同一體素只保留一個點；上限 2,000,000 點，達上限後不再加入
- [ ] 提供點數、邊界框（min/max）、中心、清除
- [ ] `PLYExporter` 輸出 binary little-endian PLY，欄位 `x y z red green blue`
- [ ] 編譯通過

### US-003: 硬體偵測首頁
**Description:** 身為使用者，我想在首頁看到這支裝置有哪些硬體、每種掃描模式能做到什麼，然後自己選。

**Acceptance Criteria:**
- [ ] 顯示裝置型號（機型識別碼對應的名稱，例如 iPhone 17；無對應時顯示識別碼）
- [ ] 顯示三項硬體狀態：LiDAR、TrueDepth、ARKit world tracking（可用／不可用）
- [ ] 四張模式卡片：名稱、深度來源、預期精度、適用物體、可用與否
- [ ] 不可用的模式卡片為停用外觀並顯示原因（例如「此裝置沒有 LiDAR」）
- [ ] 點選可用模式進入掃描畫面
- [ ] 介面為繁體中文
- [ ] 編譯通過；實機確認 iPhone 17 上 LiDAR 為停用、其餘三項可選

### US-004: Metal 點雲檢視器
**Description:** 身為使用者，我想旋轉、縮放、平移掃描出來的點雲模型。

**Acceptance Criteria:**
- [ ] 以 Metal point primitive 繪製 `PointCloudStore` 的內容，黑色背景
- [ ] 模型自動置中並縮放到適合畫面
- [ ] 單指拖曳＝軌道旋轉；捏合＝縮放；雙指拖曳＝平移；雙擊＝重置視角
- [ ] 可切換「真實色／高度色」；高度色依世界座標 y 由低到高漸層
- [ ] 點大小滑桿（1–12 px）
- [ ] 編譯通過；實機確認手勢

### US-005: 掃描畫面與 TrueDepth 模式
**Description:** 身為 iPhone 17 使用者，我想用前置 TrueDepth 掃描小物體的表面凹凸。

**Acceptance Criteria:**
- [ ] 使用 `ARFaceTrackingConfiguration`，支援時開啟 `isWorldTrackingEnabled`
- [ ] 從 `ARFrame.capturedDepthData` 取深度，用內參反投影並以相機姿態轉為世界座標
- [ ] 顏色取自同幀 `capturedImage`
- [ ] 「開始／停止」按鈕；掃描中持續累積；停止後可進入檢視器
- [ ] 相機畫面上即時疊加已累積的點
- [ ] 最遠距離滑桿（0.2–1.0 m，預設 0.6 m），最近 0.15 m
- [ ] 大字顯示已累積點數；每新增 5 萬點震動一次；達上限時提示
- [ ] 追蹤狀態不正常時顯示提示且不累積
- [ ] 「清除」按鈕重新開始
- [ ] 編譯通過；實機確認能掃出物體表面

### US-006: LiDAR 模式
**Description:** 身為有 LiDAR 裝置的使用者，我想用後置 LiDAR 繞著物體掃描。

**Acceptance Criteria:**
- [ ] `ARWorldTrackingConfiguration` + `.sceneDepth`
- [ ] 只保留信心值 high 的像素
- [ ] 距離範圍 0.2–最遠（滑桿 0.5–3.0 m，預設 1.5 m）
- [ ] 與 US-005 共用掃描畫面與累積流程
- [ ] 編譯通過（需 LiDAR 裝置實測）

### US-007: 後置特徵點模式
**Description:** 身為任何裝置的使用者，我想用後置相機掃出物體的稀疏輪廓。

**Acceptance Criteria:**
- [ ] `ARWorldTrackingConfiguration`，累積每幀 `rawFeaturePoints`
- [ ] 把每個點投影回 `capturedImage` 取顏色
- [ ] 套用距離滑桿
- [ ] 首頁與掃描畫面標示「稀疏，僅輪廓」
- [ ] 編譯通過；實機確認

### US-008: 統計與 PLY 匯出
**Description:** 身為使用者，我想看到點雲的座標資訊，並把 x y z 資料帶到其他軟體。

**Acceptance Criteria:**
- [ ] 檢視器顯示點數與邊界尺寸（寬×高×深，公分）
- [ ] 「匯出 PLY」經系統分享選單輸出檔案，檔名含時間戳
- [ ] 編譯通過；實機確認檔案可在 MeshLab／CloudCompare 開啟

### US-009: 後置 ML 估計深度模式（實驗性）
**Description:** 身為沒有 LiDAR 的使用者，我想用後置相機得到密集點雲，即使深度是估計值。

**Acceptance Criteria:**
- [ ] 專案內建 Depth Anything V2 Small Core ML 模型
- [ ] 對 `capturedImage` 推論（背景執行，同時最多一幀）
- [ ] 以該幀可見的 ARKit 特徵點對模型輸出做最小平方校正，轉為公尺深度；有效特徵點少於 12 個或擬合不合理的幀捨棄
- [ ] 介面標示「實驗性／估計深度」
- [ ] 與 US-005 共用掃描畫面與累積流程
- [ ] 編譯通過；實機確認

### US-010: 固定視角單次拍攝（取代 US-005 的持續累積）
**Description:** 身為使用者，我想把手機固定在一個角度拍一次，就得到物體看得到那一面的 x y z 點雲，不需要繞著物體移動。

**Acceptance Criteria:**
- [ ] 拍攝前即時預覽：每幀以目前深度範圍內的點取代點雲並疊加在相機畫面上
- [ ] 按「拍攝」後收集多幀深度（TrueDepth 10 幀、LiDAR 15 幀）逐像素平均，變動超過 4% 的像素捨棄
- [ ] 以全解析度反投影，不做體素去重
- [ ] 拍攝期間相機移動超過 1 cm 或 1.5° 時放棄並提示重拍
- [ ] 拍攝完成後自動開啟檢視器，初始視角接近拍攝方向；返回後可重拍
- [ ] 特徵點模式收集約 30 幀；ML 模式拍單幀
- [ ] 編譯通過；實機確認能拍出物體表面

### US-011: 只掃描準星對到的物體
**Description:** 身為使用者，我只想掃描某一個物體，不要把桌面和背景一起掃進來。

**Acceptance Criteria:**
- [ ] 以 Vision 前景主體分割取得物體遮罩，選擇畫面中央準星對到的物體
- [ ] 只有遮罩內的深度像素會轉成點，四種模式皆適用
- [ ] 預覽即時顯示隔離結果；找不到物體時顯示全部的點並提示；拍攝時找不到則提示重拍
- [ ] 「只保留準星對到的物體」開關，預設開啟
- [ ] 編譯通過；實機確認桌面被去除

## Functional Requirements

- FR-1: 啟動時偵測 LiDAR（`ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`）、TrueDepth（`ARFaceTrackingConfiguration.isSupported`）、world tracking（`ARWorldTrackingConfiguration.isSupported`）
- FR-2: 首頁列出四種模式，不支援者停用並說明原因
- FR-3: 所有模式輸出 ARKit 世界座標（公尺、右手座標系、y 軸向上）的 x y z 與 RGB
- FR-4: 固定視角單次拍攝：多幀深度逐像素平均後以全解析度反投影（僅特徵點模式以 3 mm 體素合併），上限 2,000,000 點
- FR-5: 拍攝前即時預覽疊加顯示點雲，並顯示點數
- FR-6: 依距離滑桿過濾超出範圍的點
- FR-7: 檢視器支援旋轉、縮放、平移、重置、顏色模式切換、點大小調整
- FR-8: 顯示點數與邊界尺寸，可匯出 binary PLY
- FR-9: 介面文字為繁體中文

## Non-Goals

- 掃描清單保存／重新開啟
- 三角網格重建
- 點選單點查詢座標
- 3D 邊界框選取、自動移除桌面
- 繞著物體移動的多視角累積掃描（只拍固定視角看得到的那一面）

## Design Considerations

- 首頁：硬體狀態區 + 模式卡片清單
- 掃描畫面：全螢幕相機，底部控制列（開始／停止、清除、距離滑桿、檢視）
- 檢視器：全螢幕黑底，底部工具列
- TrueDepth 模式下使用者可能看不清螢幕，以震動與大字回饋

## Technical Considerations

- 掃描畫面與檢視器共用同一個 Metal 點雲 renderer；掃描畫面以 `ARSCNView` 之外的自訂 `MTKView` 繪製相機背景與點
- 專案為 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`；影格處理在背景佇列，需明確標 `nonisolated`
- 模擬器無法執行 ARKit，自動驗證僅限編譯；掃描效果需實機確認
- `xcode-select` 指向 CommandLineTools，編譯一律以 `DEVELOPER_DIR` 指定 Xcode 27.1

## Success Metrics

- iPhone 17 上 TrueDepth 模式 30 秒內可掃出一個杯子大小物體、看得出表面起伏
- 檢視器在 100 萬點時互動不卡頓
- 匯出的 PLY 可在 MeshLab 開啟且尺寸與實物相符

## Open Questions

- ARKit 在畫面中沒有人臉時是否持續提供 `capturedDepthData`（需實機確認；若否，退路為 AVFoundation 單幀擷取）
- TrueDepth 模式開啟 world tracking 時的姿態穩定度是否足以多幀累積

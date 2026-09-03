# VietDrive

VietDrive là ứng dụng trợ lý lái xe và dẫn đường thông minh dành riêng cho thị trường Việt Nam trên nền tảng iOS (hỗ trợ Apple Watch, Live Activity / Dynamic Island và CarPlay), sử dụng bản đồ mở và cơ sở dữ liệu giao thông offline chuẩn xác. Dự án độc lập hoàn toàn, **không sử dụng** Google Maps SDK, Google Places hay Google Directions.

---

## Trạng thái hiện tại

- **Phiên bản ứng dụng**: `0.3.0` prototype nội bộ.
- **Nền tảng**: iOS 17.0 trở lên, watchOS 10.0 trở lên, viết bằng SwiftUI và Swift Concurrency.
- **Bộ hiển thị bản đồ**: MapLibre Native 6.29.0 (Swift Package Manager).
- **Lớp bản đồ nền**: Vector tiles từ OpenFreeMap/OpenStreetMap, có ambient cache 150 MB và tính năng tải offline pack cho khu vực xung quanh bán kính ~13 km.
- **Lớp dữ liệu VietDrive**: SQLite v2 Schema v6 (Contract `vn.vietdrive.map-data` v1) nhúng trực tiếp trong ứng dụng (`extracted/map_database_v2.sqlite`), truy vấn hoàn toàn offline bằng chỉ mục không gian R-Tree 2D.
- **Thiết bị đã kiểm thử**: iPhone 15 Pro, iPhone 16 series, iPhone Air; iOS 17+.
- **Bộ giọng nói**: Bộ giọng thu âm **Adam · Nam miền Nam** gồm 107 file MP3 chất lượng cao, không phụ thuộc Apple iOS TTS.
- **Nhận diện giao diện**: Phong cách buồng lái tối giản trực quan (Roadside presentation), xe Mazda CX-5 trắng nhìn từ sau, biển báo nổi bên lề đường theo khoảng cách mét thực tế, mascot đám mây “Mây” tương tác linh hoạt.
- **Định tuyến & Tìm kiếm**: Photon (geocoding tiếng Việt, bounding box Việt Nam) và OSRM/Valhalla đa phương án cho ô tô.
- **Chế độ chạy thử offline (Demo Mode)**: Tuyến cố định Sài Gòn → Phan Thiết (168,3 km, 1.263 tọa độ) đóng gói sẵn, cho phép chạy thử và nhảy mốc tiến độ mà không cần GPS thật hay kết nối mạng.

---

## Kiến trúc hệ thống

```text
                             SwiftUI Dashboard / Driving Mode
                                            │
         ┌──────────────────────────────────┼──────────────────────────────────┐
         │                                  │                                  │
         ▼                                  ▼                                  ▼
  MapLibre Native                   LocationService                    OpenMapService
  (OpenFreeMap tiles)              (CoreLocation GPS,               (Photon Search + OSRM
  Ambient cache 150MB              speed, heading, bg)                multi-route & steps)
         │                                  │                                  │
         └──────────────────────────────────┼──────────────────────────────────┘
                                            │
                                            ▼
                                  RouteProgressEngine
                             (Chiếu GPS polyline, đo ETA,
                              khoảng cách còn lại & reroute)
                                            │
                                            ▼
                                    OfflineAlertStore
                       (SQLite v2 Schema v6 + R-Tree 2D Index)
                       ├─ map_data_points (Camera, R.420, Biển tốc độ)
                       ├─ map_data_road_links (Mạng đường & tốc độ 2 chiều)
                       ├─ lookaheadNextSpeedMatch (Dự báo biển tốc độ kế)
                       └─ Section Camera (Đo tốc độ TB đoạn đường)
                                            │
                                            ▼
                                    VoiceAlertService
                         (Adam · Nam miền Nam · 107 MP3)
                         (Hàng đợi ưu tiên, khử lặp, ngắt session)
                                            │
         ┌──────────────────────────────────┼──────────────────────────────────┐
         │                                  │                                  │
         ▼                                  ▼                                  ▼
  Platform Coordinator              LiveActivity Coordinator            MascotMayView
(WatchConnectivity sync             (ActivityKit Dynamic Island        (Trạng thái Mây:
 Apple Watch VietDriveWatch)         & Lockscreen widget)               cruise, turn, alert...)
```

---

## Cơ sở dữ liệu VietDrive (`map_database_v2.sqlite`)

Tệp sản xuất nằm tại `extracted/map_database_v2.sqlite` và được tự động bundle vào `VietDriveIOS/VietDrive/Resources/map_database_v2.sqlite`.

> [!IMPORTANT]
> Tuyệt đối không chỉnh sửa tệp SQLite thủ công. Hãy sử dụng pipeline tự động `update_pipeline.py` để biên dịch từ file `secrect.bin` gốc.

### Thông tin Schema v6 (Contract `vn.vietdrive.map-data` v1)

| Bảng | Vai trò | Cấu trúc chính |
| :--- | :--- | :--- |
| **`metadata`** | Lưu version schema, contract ID, ngày build, SHA-256 nguồn | `key TEXT, value TEXT` |
| **`map_data_points`** | Hơn 36.000 điểm camera, biển báo tốc độ, khu dân cư | `source_node_id, type_code, kind, latitude, longitude, speed_kmh, direction_type, direction_degrees, warning_text` |
| **`map_data_points_rtree`** | Chỉ mục không gian 2D cho `map_data_points` | `point_id, min_lat, max_lat, min_lon, max_lon` |
| **`map_data_road_links`** | Mạng lưới đường bộ có tốc độ và tên đường 2 chiều | `road_serial_number, provider_road_id, inline_road_name, direction_1_name_id, direction_2_name_id, direction_1_speed_kmh, direction_2_speed_kmh, geometry_json` |
| **`map_data_road_links_rtree`** | Chỉ mục không gian 2D cho `map_data_road_links` | `link_id, min_lat, max_lat, min_lon, max_lon` |
| **`map_data_city_lookup`** | Danh mục Tỉnh / Thành phố giải mã từ `citiesen.bin` | `city_id, city_name` |
| **`map_data_name_lookup`** | Danh mục Quận / Huyện / Tên đường từ `districtsen.bin` | `name_id, city_id, name_text` |
| **`road_segments`** | Các đoạn đường OSM/khôi phục đã vượt kiểm tra hình học | `road_id, speed_kmh, length_meters, geometry_json` |
| **`turn_restrictions`** | Quy định cấm rẽ / cấm quay đầu từ OSM | `from_way, to_way, via_node, restriction_type` |
| **`road_rules`** | Quy định làn đường, cấm đỗ, cấm dừng theo khung giờ | `road_id, rule_type, rule_value, conditional` |
| **`alerts`** | Cụm camera và biển báo OSM đã deduplicate | `alert_id, kind, latitude, longitude, speed_limit` |
| **`data_issues`** | Nhật ký bản ghi bị cách ly và nguyên nhân | `entity_type, entity_id, reason, raw_payload` |

---

## Thuật toán Map-Matching & Cảnh báo Chuẩn Firmware

Logic so khớp và cảnh báo trong [OfflineAlertStore.swift](file:///Users/lechaukha12/Desktop/tools/vietdrive/VietDriveIOS/VietDrive/Services/OfflineAlertStore.swift) được đối chiếu chặt chẽ với firmware gốc VietMap M1 (hàm `0x00cb725c`, `0x00cb473c`):

1. **Khi xe đứng yên (`speed < 7 km/h`)**:
   - Quét bán kính dung sai **100 m** (bù trừ độ trôi GPS khi xuất phát trong hẻm/bãi đỗ).
   - Nếu đường có 2 chiều cùng tốc độ: Hiển thị ngay giới hạn tốc độ.
   - Nếu đường 1 chiều hoặc 2 chiều khác tốc độ: So khớp với hướng La bàn thiết bị (`heading`) hoặc ưu tiên tốc độ cao hơn.
   - Fallback 2 lớp: Nếu đoạn đường chưa có tốc độ, tự động tìm biển báo/camera gần nhất trong bán kính 100 m.
2. **Khi xe di chuyển (`speed >= 7 km/h`)**:
   - Quét bán kính bám làn **50 m**.
   - Tính góc phương vị của phân đoạn nhỏ $(P_i, P_{i+1})$ gần xe nhất trên polyline.
   - So sánh với góc di chuyển GPS `course`, kiểm tra độ lệch góc:
     - Góc lệch $\le 30^\circ$: Khớp chuẩn theo chiều số hóa thuận ($P_0 \to P_n$) $\to$ lấy `direction_1_speed_kmh`.
     - Góc lệch gần $180^\circ$ ($\pm 30^\circ$): Khớp chiều nghịch ($P_n \to P_0$) $\to$ lấy `direction_2_speed_kmh`.
3. **Cảnh báo Camera & Lọc Hướng**:
   - Camera trong phạm vi 3 m được gộp cụm (clustering).
   - Khi xe chạy từ 8 km/h, camera cách từ 80–450 m chỉ được phát âm thanh nếu nằm trong nón quan sát **$75^\circ$** phía trước xe.
   - Cùng một camera không lặp lại cảnh báo trong vòng **90 giây**.
4. **Camera Đo Tốc Độ Theo Đoạn (Section Camera)**:
   - Khi đi qua camera bắt đầu đoạn, ghi nhận mốc thời gian `sectionSpeedStartTime`, vị trí `sectionStartLocation` và tốc độ cho phép `sectionSpeedLimit`.
   - Tính toán liên tục **tốc độ trung bình thực tế** = $\frac{\text{quãng đường di chuyển}}{\text{thời gian trôi qua}}$ và hiển thị trên HUD để tài xế điều chỉnh ga trước khi đến trạm kiểm tra cuối đoạn.
5. **Dự báo Biển Báo Tốc Độ Tiếp Theo (`lookaheadNextSpeedMatch`)**:
   - Quét trước dọc theo hướng di chuyển từ 150 m đến 650 m.
   - Khi phát hiện đoạn đường phía trước có tốc độ giới hạn thay đổi (ví dụ: sắp giảm từ 80 km/h xuống 60 km/h), hệ thống phát cảnh báo sớm bằng giọng nói Adam: *"Phía trước tốc độ giới hạn 60 km/h"*.

---

## Hệ thống Cảnh báo Giọng nói Adam (Nam miền Nam)

VietDrive sử dụng bộ giọng độc quyền **Adam · Nam miền Nam** gồm 107 file MP3 tại [VoicePacks/south_male_adam](file:///Users/lechaukha12/Desktop/tools/vietdrive/VietDriveIOS/VietDrive/Resources/VoicePacks/south_male_adam):

- Quản lý qua [manifest.json](file:///Users/lechaukha12/Desktop/tools/vietdrive/VietDriveIOS/VietDrive/Resources/VoicePrompts/manifest.json) v2 (104 key ánh xạ).
- Các nhóm âm thanh:
  - Chỉ dẫn rẽ/vòng xuyến: `maneuver.300.*` (ở khoảng cách 80–360 m) và `maneuver.now.*` (dưới 80 m).
  - Tốc độ tiếp theo: `speed.next.{30,40,50,60,70,80,90,100,120}`.
  - Camera: `alert.camera.speed`, `alert.camera.traffic`, `alert.camera.section`, `alert.camera.dual` (`camera_ai.mp3`).
  - Khu dân cư, đường hầm, cầu vượt, trạm thu phí: `alert.town.in`, `alert.town.out`, `alert.tunnel`, `alert.toll`...
- **Hàng đợi ưu tiên (`PromptPriority`)**:
  `preview` (10) < `information` (30) < `safetyAlert` (50) < `overSpeed` (70) < `navigation` (90) < `criticalNavigation` (100).
- Khi có cảnh báo khẩn cấp hoặc chỉ dẫn rẽ tức thời, âm thanh ưu tiên thấp hơn sẽ tự động nhường hàng đợi. Không sử dụng TTS của hệ điều hành.

---

## Giao diện Buồng lái Lái xe Trực quan (Driving Mode)

Giao diện [DrivingModeView.swift](file:///Users/lechaukha12/Desktop/tools/vietdrive/VietDriveIOS/VietDrive/Views/DrivingModeView.swift) & [DrivingSceneView.swift](file:///Users/lechaukha12/Desktop/tools/vietdrive/VietDriveIOS/VietDrive/Views/DrivingSceneView.swift) cung cấp trải nghiệm tập trung, an toàn khi lái xe:

- **Xe minh họa Mazda CX-5**: Asset vector 3D sắc nét nhìn từ đuôi xe (`DrivingMazdaCX5Rear`), biển số `86A 26427`, nằm gọn gàng trên làn đường phải.
- **Đường thẳng minh họa (Symbolic Road)**: Đường 2 làn với nét đứt trắng chuyển động theo tốc độ GPS thực tế. Xe ngược chiều trang trí ở làn trái.
- **Biển báo ven đường theo khoảng cách thực (Roadside Presentation)**:
  - Tối đa 3 biển báo/camera sắp tới được dựng thành các cột biển báo ở **lề đường bên phải**.
  - Kích thước biển và khoảng cách cọc phóng to dần theo phối cảnh 3D dựa trên khoảng cách mét thực tế đo bằng GPS.
  - Tự động ẩn biển báo sau khi xe đã vượt qua.
- **Mascot Mây**: Đám mây hoạt hình tương tác theo tình trạng lái xe:
  - Bình thường / Dẫn đường: Biểu cảm tươi vui.
  - Cảnh báo rẽ: Nghiêng người chỉ hướng rẽ.
  - Cảnh báo tốc độ / Camera: Đổi màu cảnh báo và nhắc nhở.
- **Chống tắt màn hình tự động (`keepsDrivingScreenAwake`)**: Tự động giữ màn hình luôn sáng khi đang mở Chế độ lái xe ở foreground.

---

## Chế độ Chạy thử Tuyến Offline (Fixed Demo Mode)

Hỗ trợ kiểm thử đầy đủ mọi tính năng dẫn đường, HUD, cảnh báo camera và giọng nói ngay tại bàn làm việc:

- Lộ trình đóng gói: [saigon-phanthiet.json](file:///Users/lechaukha12/Desktop/tools/vietdrive/VietDriveIOS/VietDrive/Resources/Demo/saigon-phanthiet.json) (168,3 km, 1.263 điểm GPS từ TP.HCM đi Phan Thiết).
- Khởi động: Vào **Chế độ lái xe** $\to$ **Chạy thử** $\to$ **Sài Gòn → Phan Thiết**.
- Bộ điều khiển:
  - Tùy chỉnh tốc độ mô phỏng từ **10 đến 120 km/h**.
  - Nút nhảy nhanh đến các mốc hành trình: **0%**, **25%**, **50%**, **75%**, **95%**.
  - Nút Tạm dừng / Tiếp tục / Khởi động lại / Thoát.
- Demo hoạt động trên một matcher riêng biệt, không ghi đè vào GPS thật, không lưu trace rác và tự động tạm dừng khi app ra khỏi foreground.

---

## Nền tảng Đồng hành: Apple Watch & Live Activity

1. **Apple Watch (`VietDriveWatch`)**:
   - Sử dụng `WatchConnectivity` truyền nhận gói trạng thái lái xe tức thời `PlatformDriveState`.
   - Hiển thị tốc độ hiện tại, giới hạn tốc độ và biển báo sắp tới.
   - Rung phản hồi haptic khi có biển báo hoặc camera mới trong phạm vi 450 m.
2. **Live Activity & Dynamic Island (`VietDriveLiveActivity`)**:
   - Sử dụng Apple `ActivityKit` với `VietDriveActivityAttributes`.
   - Hiển thị trên Dynamic Island và Màn hình khóa: khoảng cách đến thao tác rẽ kế tiếp, icon hướng rẽ, tên đường sắp rẽ và mascot Mây.
3. **CarPlay (`CarPlaySceneDelegate`)**:
   - Tích hợp chuẩn `CPMapTemplate` của Apple CarPlay.

---

## Quy trình Cập nhật Dữ liệu 1-Click (`update_pipeline.py`)

Khi có file `secrect.bin` mới từ nhà sản xuất, chạy một lệnh duy nhất:

```bash
python3 update_pipeline.py --input /duong/dan/toi/secrect.bin
```

Script sẽ tự động:
1. **Giải mã firmware (`map-data/extract_all.py`)**: Sử dụng bảng thế S-Box `0x00cc08b0` giải mã `edogen.bin`, `citiesen.bin`, `districtsen.bin` và giải nén LZ77 `roadsenz.bin`.
2. **Chuẩn hóa SQLite v6 (`data_pipeline/normalize.py`)**: Lọc ranh giới đất liền Việt Nam, deduplicate camera 3m, tính góc bearing, lập chỉ mục không gian R-Tree 2D.
3. **Kiểm tra tính toàn vẹn**: Thực thi `PRAGMA integrity_check`.
4. **Đồng bộ vào Xcode**: Tự động ghi đè file `map_database_v2.sqlite` vào thư mục `VietDriveIOS/VietDrive/Resources/`.

---

## Hướng dẫn Build Ứng dụng iOS

Project sử dụng **XcodeGen** để đảm bảo cấu trúc project luôn đồng nhất:

```bash
cd VietDriveIOS
xcodegen generate
open VietDrive.xcodeproj
```

Build & chạy trên thiết bị hoặc Simulator:
```bash
xcodebuild -project VietDrive.xcodeproj \
  -scheme VietDrive \
  -destination 'generic/platform=iOS' \
  build
```

---

## Các tài liệu tham khảo chi tiết

- [MAP_DATA_SPEC_AND_PIPELINE.md](file:///Users/lechaukha12/Desktop/tools/vietdrive/MAP_DATA_SPEC_AND_PIPELINE.md): Đặc tả chi tiết kỹ thuật giải mã S-Box, cấu trúc khối LZ77 và schema database.
- [HOW_TO_UPDATE_MAP_DATA.md](file:///Users/lechaukha12/Desktop/tools/vietdrive/HOW_TO_UPDATE_MAP_DATA.md): Hướng dẫn nhanh cho người dùng cập nhật dữ liệu bản đồ.
- [FIRMWARE_PROVENANCE.md](file:///Users/lechaukha12/Desktop/tools/vietdrive/map-data/FIRMWARE_PROVENANCE.md): Bằng chứng dịch ngược MIPS firmware VietMap M1.
- [driving-demo-offline.md](file:///Users/lechaukha12/Desktop/tools/vietdrive/docs/driving-demo-offline.md): Tài liệu thiết kế chế độ chạy thử Sài Gòn → Phan Thiết.
- [driving-mode-design.md](file:///Users/lechaukha12/Desktop/tools/vietdrive/docs/driving-mode-design.md): Tài liệu thiết kế buồng lái 3D và roadside presentation.
- [VoicePrompts/README.md](file:///Users/lechaukha12/Desktop/tools/vietdrive/VietDriveIOS/VietDrive/Resources/VoicePrompts/README.md): Danh mục và checksum bộ giọng đọc Adam.

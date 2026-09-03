# VietDrive iOS

VietDrive 0.3.0 là ứng dụng iOS dẫn đường và trợ lý lái xe thông minh với tìm kiếm địa điểm OSM/Photon, định tuyến ô tô OSRM/Valhalla, lớp cảnh báo giao thông offline chuẩn xác, tốc độ GPS làm mượt, cảnh báo hướng di chuyển, âm thanh giọng nói Adam tiếng Việt (MP3 thu sẵn) và tự động đổi tuyến khi đi lệch. Ứng dụng độc lập hoàn toàn với Google Maps.

Giao diện sử dụng phong cách buồng lái tối giản trực quan (Roadside presentation) kết hợp bảng màu cartoon nhẹ nhàng và mascot “Mây”. Flow khởi động hiển thị onboarding 3 trang, sau đó màn hình đăng nhập thử nghiệm (`admin/admin` phục vụ prototype nội bộ).

Ứng dụng tiêu thụ cơ sở dữ liệu `extracted/map_database_v2.sqlite` (Schema v6, Contract `vn.vietdrive.map-data` v1). Sử dụng master pipeline `update_pipeline.py` để biên dịch lại database khi có dữ liệu nguồn mới.

---

## Công nghệ & Thư viện

- **SwiftUI + Swift Concurrency**: iOS 17.0 trở lên, watchOS 10.0 trở lên.
- **MapLibre Native 6.29.0**: Tích hợp qua Swift Package Manager, render vector tiles mượt mà.
- **OpenFreeMap / OSM Vector Tiles**: Lớp bản đồ nền với ambient tile cache 150 MB và hỗ trợ offline packs.
- **SQLite v2 (Schema v6)**: Read-only database nhúng trong app, truy vấn không gian cực nhanh bằng R-Tree 2D.
- **Định vị & Dẫn đường**: Photon cho tìm kiếm địa điểm; OSRM & Valhalla cho định tuyến đa phương án.
- **Âm thanh giọng nói**: Bộ giọng **Adam · Nam miền Nam** (107 file MP3 chất lượng cao).
- **Phần cứng đồng hành**: Hỗ trợ Apple Watch (`VietDriveWatch`), Dynamic Island & Lock Screen (`VietDriveLiveActivity`), và Apple CarPlay. Mã BLE companion tạm thời được loại khỏi target đang build.

Các endpoint development cấu hình trong `VietDrive/Support/Info.plist`:
- `VietDriveGeocoderBaseURL` & `VietDriveGeocoderFallbackBaseURLs`
- `VietDriveValhallaBaseURLs`
- `VietDriveRouterBaseURL` & `VietDriveRouterFallbackBaseURLs`

Màn hình **Chẩn đoán (Drive Diagnostics)** hiển thị chi tiết endpoint, latency, cache, số lượng điểm camera/đường bộ và trạng thái fallback.

---

## Cấu hình & Mở Project với XcodeGen

Project được sinh từ file `project.yml` để đảm bảo tính nhất quán:

```sh
cd VietDriveIOS
xcodegen generate
open VietDrive.xcodeproj
```

Build bằng Xcode hoặc chạy lệnh Terminal:
```sh
xcodebuild -project VietDrive.xcodeproj \
  -scheme VietDrive \
  -destination 'generic/platform=iOS' \
  build
```

---

## Tìm kiếm & Dẫn đường Động

1. **Tìm kiếm & Chọn tuyến**: Chạm ô tìm kiếm, nhập địa chỉ (Photon trả kết quả GeoJSON ưu tiên quanh vị trí hiện tại). Xem trước các tuyến thay thế (thời gian, khoảng cách, tránh thu phí/cao tốc/phà).
2. **Theo dõi hành trình**: GPS được chiếu vuông góc lên từng phân đoạn của polyline để đo khoảng cách còn lại và tính maneuver kế tiếp.
3. **Đổi tuyến tự động (Reroute)**: Thuật toán map-matching kết hợp sai số ngang, góc di chuyển (`course`) và tính liên tục. Khi ghi nhận 2 mẫu lệch rõ ràng hoặc 3 mẫu lệch/ngược hướng liên tiếp (>75 m), app tự động gọi tìm đường mới (cooldown 8 giây chống spam request khi GPS nhiễu).
4. **HUD dẫn đường**: Hiển thị giờ đến dự kiến (ETA), thời gian và quãng đường còn lại, thanh tiến độ trực quan, và biểu cảm mascot Mây tương ứng với hành động lái xe.

---

## Cơ sở dữ liệu Schema v6 & Map-Matching Chuẩn Firmware

Cơ sở dữ liệu `map_database_v2.sqlite` tuân thủ **Schema v6 (Contract v1)**:
- **`map_data_points`**: Hơn 36.000 điểm POI cảnh báo (camera tốc độ, camera đèn đỏ, camera đo tốc độ đoạn đường, biển R.420 khu đông dân cư).
- **`map_data_road_links`**: Mạng lưới đường bộ với tốc độ giới hạn 2 chiều riêng biệt (`direction_1_speed_kmh`, `direction_2_speed_kmh`) và liên kết tên đường.

### Quy tắc Map-Matching & Cảnh báo:
- **Xe dừng (`speed < 7 km/h`)**: Quét bán kính dung sai 100 m, ưu tiên tốc độ hiển thị tức thì.
- **Xe chạy (`speed >= 7 km/h`)**: Quét bán kính 50 m, so sánh góc phương vị của phân đoạn gần nhất với hướng xe chạy:
  - Góc lệch $\le 30^\circ$: Lấy tốc độ chiều thuận (`direction_1_speed_kmh`).
  - Góc lệch $\approx 180^\circ \pm 30^\circ$: Lấy tốc độ chiều nghịch (`direction_2_speed_kmh`).
- **Dự báo biển tốc độ kế tiếp (`lookaheadNextSpeedMatch`)**: Quét trước 150–650 m dọc theo tuyến, báo sớm bằng giọng nói khi sắp chuyển sang đoạn đường có giới hạn tốc độ thấp hơn.
- **Đo tốc độ trung bình đoạn đường (Section Camera)**: Khi vào khu vực camera đo đoạn, app tính toán thời gian và quãng đường đã đi để hiển thị tốc độ trung bình liên tục trên HUD.

---

## Giọng nói Cảnh báo Adam (Nam miền Nam)

Ứng dụng sử dụng bộ giọng thu sẵn độc quyền **Adam · Nam miền Nam** gồm 107 file MP3 tại `VietDrive/Resources/VoicePacks/south_male_adam`. 

- Quản lý qua `VoicePrompts/manifest.json` schema 2.
- Ánh xạ đầy đủ các câu lệnh dẫn đường, rẽ trái/phải/vòng xuyến, các loại camera (tốc độ, đèn tín hiệu, camera kép, camera đoạn), khu dân cư, đường hầm, cầu vượt, trạm thu phí và dự báo biển tốc độ tiếp theo.
- Quản lý theo hàng đợi mức độ ưu tiên (`PromptPriority`), tự động khử lặp trong 90 giây và xử lý thông minh khi có cuộc gọi hoặc âm thanh hệ thống can thiệp.
- Tuyệt đối không fallback sang TTS máy của iOS để giữ trải nghiệm âm thanh nhất quán.

---

## Buồng lái Lái xe Trực quan (Driving Mode Scene)

- **Minh họa đường thẳng**: Sử dụng đường thẳng 2 làn phong cách cartoon, các nét đứt di chuyển theo tốc độ GPS thực tế của xe.
- **Biển báo ven đường (Roadside Signs)**: Tối đa 3 biển báo hoặc camera sắp tới được cắm cọc bên lề đường phải, tự động phóng to dần theo khoảng cách mét thực tế và biến mất khi xe chạy qua.
- **Xe Mazda CX-5**: Minh họa 3D nhìn từ sau (`DrivingMazdaCX5Rear`), biển số `86A 26427`, nằm ngay ngắn ở làn đường bên phải.
- **Chống tắt màn hình (`keepsDrivingScreenAwake`)**: Tự động vô hiệu hóa chế độ khóa màn hình khi Driving Mode đang hoạt động ở foreground.

---

## Chế độ Chạy thử Tuyến Offline (Fixed Demo)

- Vào mục **Chế độ lái xe** $\to$ **Chạy thử** $\to$ **Sài Gòn → Phan Thiết**.
- Tuyến đường cố định 168,3 km gồm 1.263 tọa độ được đóng gói sẵn trong [saigon-phanthiet.json](VietDrive/Resources/Demo/saigon-phanthiet.json).
- Hỗ trợ tùy chỉnh tốc độ từ 10 đến 120 km/h và các nút nhảy nhanh mốc tiến độ (0%, 25%, 50%, 75%, 95%).
- Không phụ thuộc mạng internet, không gọi API dẫn đường và không làm ô nhiễm lịch sử GPS thật.

---

## Apple Watch, Live Activity & CarPlay

- **Apple Watch (`VietDriveWatch`)**: Nhận gói dữ liệu `PlatformDriveState` qua WatchConnectivity, hiển thị tốc độ, giới hạn tốc độ và rung haptic khi sắp gặp biển báo.
- **Live Activity (`VietDriveLiveActivity`)**: Widget Dynamic Island và Màn hình khóa hiển thị chỉ dẫn rẽ kế tiếp, khoảng cách và mascot Mây.
- **CarPlay**: Hỗ trợ template bản đồ `CPMapTemplate` đồng bộ cùng trạng thái dẫn đường của iPhone.

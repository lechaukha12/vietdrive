# VietDrive iOS

VietDrive 0.3 is an internal iOS navigation prototype with OSM place search, live OSRM
routing, validated offline overlays, camera/traffic-sign alerts, GPS speed,
heading-aware warnings, Vietnamese voice feedback and automatic rerouting. It
is not release-ready: map coverage, driving safety validation and UX testing are
still incomplete. The
BLE companion prototype remains excluded from the active target.

Giao diện prototype dùng bảng màu cartoon xanh dương nhạt–hồng và mascot “Mây”.
Flow khởi động luôn hiển thị onboarding 3 trang, sau đó login thử nghiệm bằng
`admin/admin`. Đây không phải xác thực thật và phải được thay thế trước mọi hình
thức phân phối ứng dụng.

The application consumes extracted/map_database_v2.sqlite. Rebuild that file
with data_pipeline/normalize.py after changing recovered source data.

Ứng dụng iOS nền tảng của VietDrive, không phụ thuộc Google.

## Stack

- SwiftUI + iOS 17 trở lên.
- MapLibre Native 6.29 qua Swift Package Manager.
- OpenFreeMap/OSM vector tiles cho bản đồ phát triển.
- SQLite read-only cho dữ liệu cảnh báo offline.
- Photon cho tìm kiếm địa điểm; OSRM cho tuyến ô tô và maneuver.
- Cache response tìm kiếm/tuyến và MapLibre ambient tile cache 150 MB.
- CoreLocation và AVSpeechSynthesizer. BLE đang bị loại khỏi target.

Các endpoint development nằm trong `VietDrive/Support/Info.plist`:

- `VietDriveGeocoderBaseURL`
- `VietDriveRouterBaseURL`
- `VietDriveRouterFallbackBaseURLs`

Mặc định dùng demo công cộng Photon/OSRM; khi primary lỗi HTTP/timeout app thử
OSRM dự phòng rồi mới dùng response cache cũ. Màn hình Chẩn đoán hiển thị
endpoint, latency, cache và trạng thái fallback. Trước khi phát hành vẫn phải
thay bằng instance VietDrive tự host hoặc nhà cung cấp có SLA.

## Mở project

Project được sinh bằng XcodeGen để cấu hình luôn có thể tái tạo:

```sh
cd VietDriveIOS
xcodegen generate
open VietDrive.xcodeproj
```

Máy hiện tại cài Xcode tại `/Applications/Xcode-beta.app` nhưng developer directory
đang trỏ tới Command Line Tools. Có thể chọn Xcode trong Settings > Locations hoặc dùng:

```sh
sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer
```

Sau đó tải một iOS Simulator runtime trong Xcode Settings > Components.

## Tìm kiếm và dẫn đường

Chạm ô “Bạn muốn đi đâu?”, chọn riêng điểm bắt đầu A (hoặc vị trí GPS hiện tại)
và điểm đến B, rồi xem các tuyến thay thế. Settings cho phép ưu tiên nhanh/ngắn
và yêu cầu tránh thu phí,
cao tốc hoặc phà; nếu endpoint OSRM không hỗ trợ exclude, app tự fallback và
hiển thị trạng thái rõ ràng.
Khi bắt đầu, GPS được chiếu lên geometry để tính quãng đường còn lại và maneuver.
Map matching kết hợp độ lệch ngang, course, tính liên tục và sai số GPS; app không
reroute khi fix yếu. Hai mẫu lệch rõ hoặc ba mẫu lệch/hướng ngược đã xác minh mới
kích hoạt đổi tuyến, có cooldown 8 giây.
HUD dẫn đường hiển thị giờ đến dự kiến, thời gian và quãng đường còn lại cùng
thanh tiến độ. Mascot đổi hiệu ứng theo maneuver, tốc độ, cảnh báo, reroute và
trạng thái đến nơi.

Database schema v3 tách biển vật lý, 1.659 quan hệ cấm rẽ và quy tắc trên đoạn
đường. Cảnh báo khi đang dẫn đường được chiếu lên route geometry để loại biển ở
đường song song; restriction có điều kiện ngày/giờ phổ biến được đánh giá theo
giờ thiết bị. Lane data từ OSRM được hiển thị khi endpoint cung cấp.
Biển có confidence dưới quality gate bị ẩn; metadata hướng được so với bearing
của chính đoạn tuyến. Chạm marker để xem nguồn/độ tin cậy và gửi báo sai vào hàng
chờ kiểm duyệt, không tự động xóa dữ liệu đang phát hành.

## Voice

Bản development giữ tạm bộ MP3 nữ miền Nam lấy từ thư mục VietMap đã cung cấp
trong `VietDrive/Resources/VoicePacks/south_female_1`. App ưu tiên bộ này cho
chỉ đường, camera, tốc độ và đổi tuyến; câu chưa có mới fallback sang giọng tiếng
Việt của iOS. Biển cấm rẽ chỉ hiển thị trực quan trên tuyến đường, không phát
voice. Không dùng bộ tạm này để phát hành trước khi xác nhận quyền phân phối.

## Cập nhật dữ liệu

`extracted/data_manifest.json` chứa version, checksum SHA-256 và số bản ghi.
Sau khi host database, dùng `data_pipeline/package_release.py` và cấu hình
`VietDriveDataManifestURL` trong Info.plist. App chỉ kích hoạt database tải về
sau khi kiểm tra kích thước, SHA-256 và `PRAGMA integrity_check`; bản trước được
giữ lại để rollback.

## Chạy thử không cần GPS

Chọn điểm A và B, tìm tuyến rồi nhấn “Mô phỏng” để chạy chính geometry và
chỉ dẫn của tuyến OSRM vừa chọn. Xe được nội suy liên tục ở 10 FPS và nén thời
gian x8.

## Chẩn đoán và phát lại GPS

Khi dẫn đường thật, app mặc định ghi GPS cục bộ và checkpoint mỗi 10 mẫu; giữ tối
đa 10 hành trình. Trong Settings > Chẩn đoán có thể chọn một tuyến A → B, phát lại
bản ghi x4 để tái hiện map matching, voice và reroute. Màn hình này cũng hiển thị
sai số GPS, trạng thái bám tuyến, prompt voice cuối và sức khỏe routing.

## Bản đồ offline và ban đêm

MapLibre giữ ambient cache tối đa 150 MB. Settings cho phép tải vùng khoảng 13 km
quanh vị trí hiện tại ở zoom 9–15 thành offline pack. Bản đồ có chế độ ngày, đêm
hoặc tự động theo giờ; style lấy trực tiếp từ OpenFreeMap.

## Test

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild test -project VietDrive.xcodeproj -scheme VietDrive \
  -destination 'id=00008150-000D38D92278401C'
```

## BLE cho VietDrive Box (tạm gác)

Điện thoại hoạt động như BLE peripheral:

| Thành phần | UUID |
| --- | --- |
| Service | `7E4A0001-7A54-4D52-4956-455652495645` |
| Telemetry notify/read | `7E4A0002-7A54-4D52-4956-455652495645` |
| JPEG frame notify | `7E4A0003-7A54-4D52-4956-455652495645` |
| Command write | `7E4A0004-7A54-4D52-4956-455652495645` |

Mỗi notification có header 8 byte little-endian:

```text
byte 0      protocol version (1)
byte 1      kind: 1 = JSON telemetry, 2 = JPEG frame
byte 2..3   sequence
byte 4..5   chunk index, bắt đầu từ 0
byte 6..7   tổng số chunk
byte 8..    payload
```

Ghi byte `0x01` vào command characteristic để yêu cầu gửi lại frame JPEG gần nhất.

## Giới hạn dữ liệu hiện tại

Database schema v3 được bundle để phát triển nhưng VietDrive chủ động bỏ qua toàn bộ
`toll_booth`: nguồn hiện tại đánh dấu tất cả 5.517 đoạn đường là thu phí. Map-matching
đoạn đường phục hồi chỉ bật cho 791 segment vượt quality gate. Giới hạn tốc độ
trên HUD ưu tiên 29.980 way OSM có `maxspeed`, khớp theo khoảng cách, hướng
tuyến và chiều `oneway`; giá trị ước lượng của mô phỏng không còn được trình bày
như giới hạn pháp lý. Nếu đoạn đường không có `maxspeed` đáng tin cậy, HUD hiển thị
`—`; VietDrive tuyệt đối không tự suy luận giới hạn tốc độ. Camera và biển tốc độ
được dùng như lớp cảnh báo đã gắn hướng/tuyến khi metadata cho phép.
Ngoài ra, 2.049 điểm tốc độ do người dùng cung cấp trong `speed_signs.geojson`
được đọc từ bảng `speed_observations` và hiển thị thành lớp MapLibre riêng. Điểm
này chỉ lên HUD khi GPS cách tối đa 30 m, không phát voice/haptic và không được
kéo dài sang đoạn đường khác khi chưa có hướng/phạm vi hiệu lực.
Lớp biển báo vật lý lấy từ OSM là dữ liệu cộng đồng không đầy đủ; app chỉ công bố
node có mã nhận dạng được và asset tương ứng, đồng thời lưu độ phủ thật trong
`sign_pipeline/sign_report.json`.

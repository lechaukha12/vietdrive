# VietDrive

VietDrive là ứng dụng trợ lý lái xe iOS dùng bản đồ và dữ liệu mở. Dự án không
dùng Google Maps SDK, Google Places, Google Directions hoặc Google Encoded
Polyline.

## Trạng thái hiện tại

- Phiên bản ứng dụng: 0.2.0 prototype nội bộ, chưa sẵn sàng phát hành.
- Nền tảng: iOS 17 trở lên, SwiftUI.
- Bộ hiển thị bản đồ: MapLibre Native 6.29.
- Lớp nền: OpenFreeMap/OpenStreetMap, hiện cần kết nối mạng để tải tile.
- Lớp VietDrive: SQLite v2 nhúng trong ứng dụng, truy vấn offline bằng RTree.
- Thiết bị đã kiểm thử: iPhone Air, iOS 27.
- BLE/ESP32: tạm gác; mã thử nghiệm được giữ nhưng không thuộc target đang build.
- Asset biển báo: bộ tuyển chọn 25 hình public-domain, có manifest nguồn và hash.
- Nhận diện giao diện: cartoon xanh dương nhạt–hồng với mascot “Mây”; app icon
  và các pose mascot được nhúng trong Asset Catalog.

Ứng dụng hiện có tìm kiếm địa điểm, định tuyến ô tô, theo dõi tiến trình tuyến,
đổi tuyến khi đi lệch, bản đồ, vị trí GPS, tốc độ, hướng di chuyển, camera gần
xe, lớp biển báo OSM thử nghiệm, cảnh báo giọng nói tiếng Việt, lớp đường đã
vượt kiểm tra hình học, lọc lớp dữ liệu và chế độ mô phỏng. Đây là nền móng để
kiểm thử, chưa phải sản phẩm hoàn thiện.

Mỗi lần khởi động hiện đi qua onboarding 3 trang rồi màn hình đăng nhập. Tài
khoản `admin/admin` chỉ là fixture hard-code phục vụ prototype, tuyệt đối không
được xem là cơ chế xác thực hoặc giữ lại trong bản phát hành. Settings cho phép
bật/tắt giọng nói, mascot, chuyển động, rung, các lớp dữ liệu, mô phỏng và đăng
xuất.

Khi xem trước hoặc đang chạy tuyến, HUD hiển thị đồng thời giờ dự kiến đến,
thời gian còn lại, quãng đường còn lại và thanh tiến độ. Các giá trị giảm theo
vị trí đã map-match trên tuyến; chế độ mô phỏng dùng thời gian lái xe thực của
fixture thay vì thời gian đã nén. Mây có trạng thái riêng cho tìm tuyến, chạy
thẳng, rẽ trái/phải, cảnh báo, quá tốc độ, tái định tuyến và đến nơi; cài đặt
Giảm chuyển động sẽ tắt các animation lặp.

Tìm kiếm dùng Photon và tuyến động dùng OSRM/OpenStreetMap; các endpoint nằm
trong Info.plist để thay mà không sửa logic. Demo công cộng chỉ phù hợp phát
triển, chưa có SLA. Nguồn đường khôi phục vẫn không được dùng làm routing graph.

## Kiến trúc

    SwiftUI dashboard
          |
          +-- MapLibre Native -> OpenFreeMap / OpenStreetMap base tiles
          |
          +-- LocationService -> Core Location GPS, speed, heading
          |
          +-- OpenMapService -> Photon search + OSRM route/steps
          |
          +-- RouteProgressEngine -> map projection + remaining distance
          |
          +-- OfflineAlertStore -> SQLite v2 + RTree
          |       +-- camera alerts
          |       +-- recognized OSM traffic signs
          |       +-- validated road overlays
          |       +-- nearest-road speed matching
          |
          +-- VoiceAlertService -> Vietnamese TTS and repeat suppression

          +-- AppSessionModel -> onboarding -> prototype login -> drive

          +-- MascotMayView -> idle / search / cruise / turn / alert / reroute / arrive

Lớp nền và lớp dữ liệu VietDrive độc lập. Mất mạng không làm mất camera, dữ
liệu đường đã nhúng, GPS, HUD hoặc TTS; tuy nhiên các tile nền chưa lưu cache có
thể không hiển thị.

## Cơ sở dữ liệu v2

File sản xuất là extracted/map_database_v2.sqlite. Không chỉnh file này bằng
tay; hãy thay đổi quy tắc trong data_pipeline/normalize.py rồi tạo lại.

Các bảng chính:

| Bảng | Vai trò |
| --- | --- |
| metadata | phiên bản schema, quy tắc và SHA-256 của nguồn |
| alerts | cụm camera và biển báo OSM đã sàng lọc |
| alerts_rtree | chỉ mục không gian cảnh báo |
| road_segments | đoạn đường vượt kiểm tra hình học |
| road_segments_rtree | chỉ mục không gian đoạn đường |
| speed_observations | quan sát tốc độ chỉ để tham khảo |
| data_issues | bản ghi bị cách ly và nguyên nhân |

Kết quả chất lượng hiện tại:

| Dataset | Nguồn | Sản xuất | Cách xử lý |
| --- | ---: | ---: | --- |
| Camera | 3.892 | 3.603 cụm | loại 129 điểm ngoài biên, hợp nhất 160 điểm gần trùng |
| Đoạn đường | 5.517 | 791 | cách ly 4.726 đoạn có cạnh phi lý |
| Đường có tốc độ đã biết | 2.049 quan sát | 329 đoạn hợp lệ | map-match trong bán kính 45 m |
| Thu phí | 5.517 cờ nguồn | 0 | cách ly toàn bộ vì mọi đường đều bị gán thu phí |
| Biển báo OSM | 822 node liên quan | 134 (snapshot 25/08/2026) | 635 node `traffic_sign=yes` không đủ thông tin; chỉ công bố mã có asset tương ứng |

Nhãn tỉnh trong nguồn cũ được giữ để truy vết, không hiển thị như dữ liệu chính
thức. Các điểm speed_limit được coi là quan sát tham khảo, không khẳng định là
vị trí biển báo vật lý.

## Quy tắc cảnh báo và map matching

- Camera trong phạm vi 3 m được hợp nhất bằng spatial buckets và union-find.
- Khi xe chạy từ 8 km/h, camera xa hơn 70 m chỉ được giữ nếu nằm trong nón 75
  độ phía trước.
- Camera gần nhất từ 80–450 m có thể phát TTS; cùng một camera không lặp trong
  90 giây.
- Giới hạn tốc độ chỉ được nhận từ đoạn đường hợp lệ cách vị trí tối đa 45 m.
- Khi xe chạy, hướng đường phải lệch không quá 55 độ so với hướng xe, tính cả
  hai chiều số hóa.
- Vượt tốc chỉ kích hoạt khi đã map-match được giới hạn lớn hơn 0.

## Tìm kiếm và dẫn đường động

- Photon trả địa điểm dạng GeoJSON, ưu tiên quanh vị trí hiện tại và giới hạn
  bounding box Việt Nam.
- OSRM trả tối đa ba phương án; app chọn phương án có khoảng cách ngắn nhất,
  geometry đầy đủ và danh sách maneuver.
- GPS được chiếu lên từng đoạn của polyline để tính quãng đường còn lại.
- Ba mẫu GPS liên tiếp cách tuyến trên 75 m kích hoạt đổi tuyến; cooldown 15
  giây ngăn lặp request khi tín hiệu nhiễu.
- TTS thông báo maneuver ở các ngưỡng 500 m, 180 m và 60 m.
- OSRM không được dùng để suy đoán giới hạn tốc độ. HUD chỉ hiện giới hạn khi
  map-match được dữ liệu VietDrive/OSM tương ứng.

## Fixture hành trình TP.HCM → Phan Thiết

Pipeline `route_pipeline/build_demo.py` lấy tuyến hợp lệ ngắn nhất trong các
phương án trả về bởi OSRM, giữ geometry đầy đủ và danh sách thao tác rẽ. Fixture
hiện tại dài 168,3 km, gồm 1.263 điểm và 28 thao tác.

Mô phỏng cập nhật ở 10 FPS và nội suy liên tục theo khoảng cách, vì vậy xe đi
dọc theo đường thay vì nhảy qua một danh sách waypoint thưa. Tốc độ hiển thị là
90% giới hạn của đoạn đường và tăng/giảm dần; thời gian không gian được nén x8
để kiểm thử thuận tiện. Trong 1.263 điểm, 899 điểm (71,2%) có `maxspeed` OSM;
364 điểm còn lại được đánh dấu `conservative_fallback`, không được trình bày như
giới hạn pháp lý đã xác minh.

Endpoint OSRM/Overpass công cộng chỉ dùng để tạo fixture phát triển. Bản phát
hành phải tự host hoặc dùng nhà cung cấp có SLA và chính sách sử dụng phù hợp.

## Tạo lại dữ liệu

Yêu cầu Python 3, không cần thư viện ngoài:

    cd data_pipeline
    python3 -m unittest -v
    python3 normalize.py

Kết quả:

- extracted/map_database_v2.sqlite
- data_pipeline/reports/data_quality.json
- data_pipeline/reports/data_quality.md

Pipeline kiểm tra PRAGMA integrity_check, đặt PRAGMA user_version = 2 và lưu
SHA-256 của từng GeoJSON nguồn.

Lớp biển báo được tạo trước từ bản trích xuất OSM Việt Nam. Báo cáo luôn tách
số node thô, số biển được công bố và mã chưa nhận dạng; dữ liệu cộng đồng OSM
không được mô tả như danh mục biển báo pháp lý đầy đủ.

    cd sign_pipeline
    python3 -m venv .venv
    .venv/bin/pip install osmium
    .venv/bin/python build_signs.py

## Asset biển báo giao thông

Thư mục traffic_sign_assets chứa pipeline lấy asset từ Wikimedia Commons. Chuẩn
pháp lý đối chiếu là QCVN 41:2024/BGTVT có hiệu lực từ 01/01/2025.

Bộ hiện tại có 25 biển thiết yếu: tốc độ 30 đến 120 km/h, đường cấm, cấm đi
ngược chiều, STOP, cấm vượt, cấm rẽ, cấm dừng/đỗ, nhường đường, hướng bắt buộc,
người đi bộ, trẻ em, đi chậm và đường cao tốc.
Mỗi file có URL nguồn, URL trang mô tả, license và SHA-256 trong manifest.json.
Pipeline chỉ nhận file được Commons API báo là Public domain.

    cd traffic_sign_assets
    python3 fetch_assets.py

Các hình được nhập vào Xcode Assets dưới namespace TrafficSigns. Trạng thái
public-domain chỉ cho phép tái sử dụng; từng hình vẫn phải được đối chiếu trực
quan với phụ lục QCVN 41:2024 trước khi dùng cho chức năng an toàn.

## Build iOS

Project Xcode được sinh từ VietDriveIOS/project.yml:

    cd VietDriveIOS
    xcodegen generate
    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
      xcodebuild -project VietDrive.xcodeproj \
      -scheme VietDrive \
      -destination 'id=00008150-000D38D92278401C' \
      -allowProvisioningUpdates build

Bundle ID là vn.vietdrive.ios. Team ký cá nhân nằm trong project.yml; cần đổi
giá trị này nếu build bằng tài khoản Apple Developer khác.

## Giới hạn cần giải quyết tiếp

1. Tự host Photon và Valhalla/OSRM; chuyển endpoint khỏi demo công cộng.
2. Xây tile cache/offline region có điều khoản sử dụng rõ ràng.
3. Đối soát camera với nguồn có ngày cập nhật, loại camera cũ và bổ sung hướng
   camera khi có bằng chứng.
4. Chuẩn hóa địa giới hành chính Việt Nam hiện hành bằng polygon tin cậy thay
   cho nhãn tỉnh khôi phục.
5. Thêm test hiệu năng, test hành trình GPS ghi sẵn và test UI.
6. Thiết kế cơ chế cập nhật database có chữ ký trước khi phát hành.

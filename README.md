# 🚗 VietDrive

<p align="center">
  <b>Trợ lý lái xe & Dẫn đường thông minh cho người Việt trên nền tảng iOS</b><br>
  <i>Hoàn toàn độc lập với Google Maps · Dữ liệu giao thông offline chuẩn xác · Giọng nói tiếng Việt độc quyền</i>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2017%2B%20%7C%20watchOS%2010%2B-blue?logo=apple" alt="Platform iOS & watchOS" />
  <img src="https://img.shields.io/badge/Swift-5.9%2B%20%7C%20SwiftUI-orange?logo=swift" alt="Swift & SwiftUI" />
  <img src="https://img.shields.io/badge/MapLibre-Native%206.29-green" alt="MapLibre Native" />
  <img src="https://img.shields.io/badge/Database-SQLite%20v2%20Schema%20v6-lightgrey?logo=sqlite" alt="SQLite v2 Schema v6" />
  <img src="https://img.shields.io/badge/Version-0.3.0%20(Dev)-blueviolet" alt="Version 0.3.0" />
</p>

---

## 🌟 Giới Thiệu

**VietDrive** là ứng dụng trợ lý lái xe và dẫn đường thông minh được thiết kế tối ưu riêng cho điều kiện giao thông tại Việt Nam. Ứng dụng kết hợp giữa công nghệ bản đồ vector mã nguồn mở hiện đại ([MapLibre Native](https://maplibre.org/) + [OpenFreeMap](https://openfreemap.org/)) và hệ thống cảnh báo giao thông offline chuẩn xác được trích xuất từ dữ liệu camera hành trình chuyên dụng.

### ✨ Tính Năng Nổi Bật

- 📍 **Dẫn đường & Tìm kiếm thông minh**: Tìm kiếm địa điểm tiếng Việt qua Photon và tính toán lộ trình ô tô đa phương án qua OSRM/Valhalla.
- 📷 **Hệ thống Cảnh báo Giao thông Offline**: Hơn 36.000 điểm camera phạt nguội, camera tốc độ, camera đèn đỏ, camera đo tốc độ đoạn đường và điểm vào/ra khu dân cư (biển R.420/R.421) lưu trong SQLite R-Tree 2D offline.
- 🛣️ **Map-Matching chuẩn xác theo chiều di chuyển**: Tự động nhận diện tốc độ tối đa cho phép theo chiều thuận/nghịch của xe chạy, đo tốc độ trung bình trong đoạn đường có camera đoạn đường và dự báo trước biển báo tốc độ tiếp theo.
- 🎙️ **Bộ giọng nói Adam (Nam miền Nam)**: 107 file âm thanh MP3 tự nhiên chất lượng cao, cảnh báo rõ ràng, không phụ thuộc Apple TTS.
- 🚘 **Buồng lái Trực quan (Driving Mode 3D Scene)**: Mô phỏng buồng lái trực diện với xe Mazda CX-5, các cột biển báo hiển thị ở lề đường bên phải theo khoảng cách mét thực tế và mascot đám mây "Mây" tương tác sinh động.
- ⏱️ **Chế độ Chạy thử Offline (Fixed Demo)**: Chạy thử toàn bộ lộ trình Sài Gòn → Phan Thiết (168 km) với các mốc tiến độ (0/25/50/75/95%) mà không cần GPS thật hay kết nối mạng.
- ⌚ **Đồng hành Đa nền tảng**: Hỗ trợ Apple Watch (`VietDriveWatch`), Dynamic Island & Màn hình khóa (`VietDriveLiveActivity`), và Apple CarPlay.

---

## 🏛️ Kiến Trúc Hệ Thống

```text
┌────────────────────────────────────────────────────────────────────────┐
│                          VietDrive iOS App                             │
│                                                                        │
│   ┌─────────────────────┐   ┌──────────────────┐   ┌────────────────┐  │
│   │ MapLibre Native     │   │ LocationService  │   │ OpenMapService │  │
│   │ Vector Tiles        │   │ CoreLocation GPS │   │ Photon & OSRM  │  │
│   └──────────┬──────────┘   └────────┬─────────┘   └───────┬────────┘  │
│              │                       │                     │           │
│              └───────────────────────┼─────────────────────┘           │
│                                      ▼                                 │
│                           RouteProgressEngine                          │
│                     (Đo khoảng cách, ETA & Reroute)                    │
│                                      │                                 │
│                                      ▼                                 │
│                              OfflineAlertStore                         │
│                    (SQLite v2 Schema v6 + R-Tree 2D)                   │
│                                      │                                 │
│                                      ▼                                 │
│                              VoiceAlertService                         │
│                       (Adam · Nam miền Nam · 107 MP3)                  │
│                                      │                                 │
│              ┌───────────────────────┼─────────────────────┐           │
│              ▼                       ▼                     ▼           │
│        DrivingModeView          VietDriveWatch    VietDriveLiveActivity│
│     (3D Roadside Cockpit)       (Apple Watch)       (Dynamic Island)   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 📁 Cấu Trúc Thư Mục Dự Án

```
vietdrive/
├── VietDriveIOS/            # Mã nguồn ứng dụng iOS, Apple Watch, Live Activity & Tests
│   ├── VietDrive/           # Target iOS chính (App, ViewModels, Views, Services, Resources)
│   ├── VietDriveWatch/      # Ứng dụng độc lập cho Apple Watch
│   ├── VietDriveLiveActivity/# Widget Dynamic Island & Màn hình khóa (ActivityKit)
│   ├── Shared/              # Trạng thái dùng chung giữa iOS, Watch và Live Activity
│   ├── VietDriveTests/      # Bộ unit tests cho ứng dụng
│   └── project.yml          # Cấu hình XcodeGen tạo VietDrive.xcodeproj
│
├── map-data/                # Công cụ Reverse-Engineering giải mã firmware MIPS (secrect.bin)
│   ├── extract_all.py       # Giải mã S-Box (0x00cc08b0) và giải nén LZ77 bitstream
│   └── FIRMWARE_PROVENANCE.md# Tài liệu bằng chứng dịch ngược firmware
│
├── data_pipeline/           # Pipeline chuẩn hóa dữ liệu & xây dựng SQLite v2
│   ├── normalize.py         # Lọc tọa độ, clustering camera, tạo chỉ mục không gian R-Tree
│   └── test_normalize.py    # Unit tests cho data pipeline
│
├── route_pipeline/          # Công cụ sinh dữ liệu lộ trình demo TP.HCM → Phan Thiết
├── sign_pipeline/           # Trích xuất biển báo giao thông từ OpenStreetMap
├── restriction_pipeline/   # Trích xuất quy định cấm rẽ từ OpenStreetMap
├── traffic_sign_assets/     # Bộ sưu tập biển báo giao thông chuẩn QCVN 41:2024 (SVG/PNG)
├── extracted/               # Database sản xuất (map_database_v2.sqlite) & GeoJSON
├── update_pipeline.py       # Script tự động hóa "1-click" toàn bộ luồng cập nhật dữ liệu
└── VietDriveLanding/        # Landing page giới thiệu ứng dụng (React 19 / Next.js)
```

---

## 🚀 Cài Đặt & Chạy Thử

### 1. Yêu cầu hệ thống
- macOS có cài đặt **Xcode 15 trở lên** (khuyên dùng Xcode 16 / iOS 17+ SDK).
- Python 3.10+ (để chạy pipeline dữ liệu, không cần cài thêm thư viện ngoài).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

### 2. Tạo Xcode Project & Mở ứng dụng
```bash
cd VietDriveIOS
xcodegen generate
open VietDrive.xcodeproj
```

### 3. Build từ Command Line
```bash
cd VietDriveIOS
xcodebuild -project VietDrive.xcodeproj \
  -scheme VietDrive \
  -destination 'generic/platform=iOS' \
  build
```

---

## 🔄 Cập Nhật Dữ Liệu Bản Đồ (1-Click Pipeline)

Mỗi khi có tệp container `secrect.bin` mới từ camera hành trình, chạy một lệnh duy nhất:

```bash
python3 update_pipeline.py --input /path/to/secrect.bin
```

Hệ thống sẽ tự động:
1. Giải mã S-Box và giải nén LZ77 toàn bộ mạng đường bộ và POI cảnh báo.
2. Chuẩn hóa Schema v6 và tạo chỉ mục không gian R-Tree 2D.
3. Kiểm tra tính toàn vẹn cơ sở dữ liệu (`PRAGMA integrity_check`).
4. Tự động đồng bộ vào thư mục tài nguyên của app iOS (`VietDriveIOS/VietDrive/Resources/map_database_v2.sqlite`).

---

## 📚 Tài Liệu Kỹ Thuật

- 📖 **[WIKI.md](WIKI.md)**: Tài liệu kỹ thuật chi tiết toàn diện của dự án VietDrive.
- 🗺️ **[MAP_DATA_SPEC_AND_PIPELINE.md](MAP_DATA_SPEC_AND_PIPELINE.md)**: Đặc tả kỹ thuật giải mã S-Box, thuật toán nén LZ77 và cấu trúc cơ sở dữ liệu SQLite Schema v6.
- ⚡ **[HOW_TO_UPDATE_MAP_DATA.md](HOW_TO_UPDATE_MAP_DATA.md)**: Hướng dẫn nhanh cho người dùng cập nhật dữ liệu bản đồ.
- 🔬 **[map-data/FIRMWARE_PROVENANCE.md](map-data/FIRMWARE_PROVENANCE.md)**: Bằng chứng dịch ngược MIPS firmware camera hành trình.
- 🎨 **[docs/driving-mode-design.md](docs/driving-mode-design.md)** & **[docs/driving-demo-offline.md](docs/driving-demo-offline.md)**: Tài liệu thiết kế giao diện buồng lái 3D và chế độ chạy thử offline.
- 🔊 **[VoicePrompts/README.md](VietDriveIOS/VietDrive/Resources/VoicePrompts/README.md)**: Danh mục âm thanh và checksum của bộ giọng nói Adam.

---

## 📄 Bản Quyền & Giấy Phép

- Dữ liệu bản đồ cơ sở: © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors (ODbL).
- Vector Tiles: [OpenFreeMap](https://openfreemap.org/).
- Biển báo giao thông: Tuân thủ quy chuẩn quốc gia [QCVN 41:2024/BGTVT](traffic_sign_assets/README.md).

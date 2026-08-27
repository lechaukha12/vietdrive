# 🗺️ VIETMAP MAP DATA REVERSE ENGINEERING & DATA PIPELINE SPECIFICATION
**Tài liệu Đặc tả Kỹ thuật Dữ liệu Bản đồ & Hướng dẫn Data Pipeline Tự động cho Ứng dụng VietDrive iOS**

---

## 1. Tổng Quan Kiến Trúc & Nguồn Dữ Liệu (Architecture Overview)

Dữ liệu cảnh báo giao thông và mạng lưới đường bộ được trích xuất từ 2 nguồn chính của camera hành trình:
1. **`FW96670A.bin`**: Firmware RTOS vi xử lý Novatek NT96670 Dual-Core MIPS32.
2. **`secrect.bin`**: Container nén và mã hóa chứa toàn bộ cơ sở dữ liệu biển báo, camera giám sát và mạng lưới đường bộ Việt Nam.

```
[ secrect.bin mới từ hãng ]
             │
             ▼  (extract_all.py)
   ┌────────────────────────────────────────────────────────┐
   │ • edogen.bin      ──> S-Box ──> traffic_points.csv     │ (36,820 điểm camera / biển báo)
   │ • citiesen.bin    ──> S-Box ──> cities.csv             │ (34 tỉnh / thành phố)
   │ • districtsen.bin ──> S-Box ──> districts.csv          │ (3,321 quận / huyện / tên đường)
   │ • roadsenz.bin    ──> LZ77  ──> S-Box ──> road_links.csv│ (1,875,900 đoạn đường)
   └────────────────────────────────────────────────────────┘
             │
             ▼  (normalize.py)
   [ map_database_v2.sqlite (Chỉ mục không gian R-Tree 2D) ]
             │
             ▼  (Tự động đồng bộ)
   [ VietDriveIOS/VietDrive/Resources/map_database_v2.sqlite ]
```

---

## 2. Cơ Chế Mã Hóa & Thuật Toán Giải Mã (Decryption & Decompression)

### 2.1. Bảng Thế Tĩnh S-Box (Substitution Box)
Thuật toán mã hóa của VietMap sử dụng bảng thế tĩnh 256-byte trích xuất từ Firmware Partition 2 (Địa chỉ bộ nhớ ảo VA `0x01CAD210`):

$$\text{DecryptedByte} = \text{SBox}[\text{EncryptedByte} \oplus \text{0xAA}]$$

```python
SBOX = bytes([
    0x84, 0xa7, 0x38, 0xc4, 0xd5, 0x37, 0x40, 0xc7, 0xb7, 0x09, 0xa3, 0x58, 0x1c, 0xd7, 0x82, 0x22,
    0xcd, 0xd6, 0x8e, 0x1f, 0xaf, 0xe9, 0x70, 0x68, 0x44, 0x14, 0x69, 0x4c, 0x74, 0x34, 0x35, 0x9f,
    0xee, 0x36, 0x54, 0x8a, 0xe6, 0xce, 0x4f, 0x91, 0x31, 0x0d, 0xbf, 0x0c, 0x8c, 0x04, 0x27, 0x98,
    0x29, 0x17, 0x1b, 0x93, 0xcf, 0x9e, 0x5b, 0xb6, 0x6a, 0x5e, 0xc5, 0x39, 0x5f, 0xa2, 0x48, 0x7f,
    0xad, 0x9d, 0x99, 0xa5, 0x96, 0x72, 0x03, 0x4e, 0x23, 0x77, 0x3f, 0x0b, 0xc9, 0xb4, 0x2f, 0x19,
    0x73, 0x8d, 0x79, 0xfc, 0xd3, 0x9a, 0x0f, 0x01, 0x15, 0xcc, 0xc1, 0xc8, 0xf0, 0xf5, 0x52, 0x16,
    0x64, 0xdc, 0x67, 0xe4, 0x3d, 0x30, 0x0e, 0x62, 0xeb, 0x51, 0x12, 0x05, 0x59, 0x7d, 0xd1, 0x9c,
    0x90, 0x6f, 0x7e, 0x33, 0xca, 0x47, 0x95, 0x78, 0x4a, 0xf4, 0x07, 0x06, 0xb3, 0xb1, 0x85, 0x13,
    0x80, 0xe7, 0x2d, 0xf6, 0x80, 0x1e, 0xdf, 0xe2, 0xa9, 0x3b, 0xd2, 0x4b, 0x60, 0x61, 0xbb, 0xe3,
    0x90, 0xf7, 0xd9, 0x2e, 0xfa, 0x97, 0xde, 0xa8, 0xed, 0x5a, 0x46, 0x3e, 0xfd, 0xf9, 0xb9, 0xf8,
    0x10, 0xac, 0x6c, 0xb2, 0x7a, 0xb5, 0xc3, 0xf2, 0x6e, 0x18, 0xfe, 0x45, 0xa1, 0xc6, 0x66, 0x2b,
    0x41, 0xea, 0x2a, 0xe1, 0xa6, 0x71, 0xf1, 0x00, 0x65, 0xf3, 0x5d, 0x50, 0x43, 0x9b, 0xda, 0x3c,
    0xec, 0x75, 0x11, 0xc0, 0xdd, 0xaa, 0xb0, 0xba, 0x3a, 0xae, 0x89, 0xd4, 0xbd, 0xa4, 0x32, 0x7b,
    0x7c, 0x94, 0x1a, 0x8b, 0x81, 0x28, 0x24, 0xe0, 0xe8, 0x55, 0x5c, 0x0a, 0xff, 0x57, 0x02, 0x25,
    0xe0, 0xb8, 0xcb, 0x2c, 0x21, 0x53, 0xd8, 0x49, 0x92, 0xa0, 0xab, 0x6d, 0xef, 0x26, 0x4d, 0xc2,
    0x20, 0xd0, 0x8f, 0x86, 0xdb, 0x63, 0xbe, 0x83, 0x42, 0x08, 0xbc, 0xfb, 0xe5, 0x56, 0x6b, 0x87
])
```

### 2.2. Thuật Toán Giải Nén Mạng Đường Bộ (`roadsenz.bin`)
* Cấu trúc khối: Header 32 byte chứa tổng số block (4,280 blocks). Mỗi block có bảng mục lục 12 byte: `[uncompressed_size, compressed_size, checksum]`.
* Thuật toán nén: **LZ77 Bitstream MSB-first Sliding-Window** (được tái hiện sạch từ hàm firmware MIPS32 `0x00cb275c`).
* Mỗi block được giải nén thành đúng **65,536 bytes** (64KB), sau đó áp dụng S-Box để giải mã luồng nhị phân `roadsen.bin`.

---

## 3. Cấu Trúc Dữ Liệu Sau Khi Giải Mã (Decoded Specifications)

### 3.1. Điểm Cảnh Báo & Biển Báo (`edogen.bin` $\to$ `traffic_points.csv`)
Định dạng dạng bảng phân tách bằng dấu Tab:
```tsv
POINT_X	POINT_Y	TYPE	Speed	DirType	Direction
106.685123	10.775512	1	60	1	90
```

| Trường Dữ Liệu | Kiểu Dữ Liệu | Ý Nghĩa Kỹ Thuật |
| :--- | :--- | :--- |
| **`POINT_X`** | `Float` | Kinh độ (Longitude) WGS84. |
| **`POINT_Y`** | `Float` | Vĩ độ (Latitude) WGS84. |
| **`TYPE`** | `Integer` | **1**: Camera tốc độ / Biển tốc độ.<br>**2**: Camera phạt nguội đèn tín hiệu.<br>**4**: Đoạn đường cấm vượt / Camera đo tốc độ đoạn.<br>**10**: Điểm vào khu đông dân cư (R.420).<br>**11**: Camera phạt nguội kép (Đèn đỏ + Tốc độ). |
| **`Speed`** | `Integer` | Tốc độ giới hạn (km/h): `30, 40, 50, 60, 70, 80, 90, 100, 110, 120`. |
| **`DirType`** | `Integer` | **0**: Đa hướng, **1**: Một hướng xác định, **2**: Hai hướng ngược chiều. |
| **`Direction`** | `Integer` | Góc phương vị quét của camera ($0^\circ - 359^\circ$, tính từ Bắc theo chiều kim đồng hồ). |

---

### 3.2. Mạng Lưới Đường Bộ (`roadsenz.bin` $\to$ `road_links.csv`)
Mỗi bản ghi đại diện cho 1 đoạn Polyline đường có hướng:

| Trường Dữ Liệu | Kiểu Dữ Liệu | Ý Nghĩa Kỹ Thuật |
| :--- | :--- | :--- |
| **`road_serial_number`** | `Integer` | Mã định danh phân đoạn (Segment Index). |
| **`provider_road_id`** | `Integer` | Mã nhóm tuyến đường nội bộ của nhà cung cấp. |
| **`inline_road_name`** | `String` | Tên đường nhúng trực tiếp (nếu có). |
| **`direction_1_name_id`** | `Integer` | ID tham chiếu tên đường chiều thuận $\to$ `map_data_name_lookup`. |
| **`direction_2_name_id`** | `Integer` | ID tham chiếu tên đường chiều nghịch $\to$ `map_data_name_lookup`. |
| **`direction_1_speed_kmh`** | `Integer` | **Tốc độ giới hạn chiều thuận** (theo thứ tự tọa độ $P_0 \to P_n$). |
| **`direction_2_speed_kmh`** | `Integer` | **Tốc độ giới hạn chiều nghịch** ($P_n \to P_0$). |
| **`geometry_json`** | `JSON Array` | Mảng tọa độ Polyline: `[[lon1, lat1], [lon2, lat2], ...]`. |

---

### 3.3. Bảng Tham Chiếu Địa Danh (`cities.csv` & `districts.csv`)
* `cities.csv`: `id, label` (Ví dụ: `1, TP. Hồ Chí Minh`, `2, Hà Nội`...).
* `districts.csv`: `id, city_id, label` (Danh mục tên quận, huyện và tên các tuyến đường).

---

## 4. Cấu Trúc Cơ Sở Dữ Liệu SQLite (`map_database_v2.sqlite`)

Cơ sở dữ liệu trên iOS được thiết kế theo **Schema v6 (Contract v1)** với chỉ mục không gian R-Tree 2D:

### 4.1. Bảng `map_data_points` & `map_data_points_rtree`
```sql
CREATE TABLE map_data_points (
    id INTEGER PRIMARY KEY,
    source_node_id INTEGER NOT NULL,
    type_code INTEGER NOT NULL,
    kind TEXT NOT NULL,
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    speed_kmh INTEGER NOT NULL DEFAULT 0,
    direction_type INTEGER NOT NULL DEFAULT 0,
    direction_degrees REAL,
    raw_direction REAL,
    warning_text TEXT NOT NULL,
    source TEXT NOT NULL,
    source_ref TEXT,
    confidence REAL NOT NULL DEFAULT 1.0
);

CREATE VIRTUAL TABLE map_data_points_rtree USING rtree(
    point_id, min_lat, max_lat, min_lon, max_lon
);
```

### 4.2. Bảng `map_data_road_links` & `map_data_road_links_rtree`
```sql
CREATE TABLE map_data_road_links (
    id INTEGER PRIMARY KEY,
    road_serial_number INTEGER NOT NULL,
    provider_road_id INTEGER NOT NULL,
    inline_road_name TEXT NOT NULL DEFAULT '',
    direction_1_name_id INTEGER NOT NULL DEFAULT 0,
    direction_2_name_id INTEGER NOT NULL DEFAULT 0,
    direction_1_speed_kmh INTEGER NOT NULL DEFAULT 0,
    direction_2_speed_kmh INTEGER NOT NULL DEFAULT 0,
    geometry_json TEXT NOT NULL,
    source TEXT NOT NULL,
    confidence REAL NOT NULL DEFAULT 1.0
);

CREATE VIRTUAL TABLE map_data_road_links_rtree USING rtree(
    link_id, min_lat, max_lat, min_lon, max_lon
);
```

---

## 5. Thuật Toán Map-Matching Chuẩn Firmware Trên iOS

Ứng dụng iOS sử dụng thuật toán 2 tầng tương tự Firmware RTOS:

1. **Khi xe đứng yên (`speed < 7 km/h`):**
   * Quét bán kính dung sai **$100\text{m}$** (bù trừ sai số GPS ban đầu trong hẻm/bãi xe).
   * Nếu đường có tốc độ 2 chiều giống nhau (`Speed1 == Speed2`): Hiển thị ngay lập tức biển tốc độ.
   * Nếu là đường 1 chiều: Lấy giá trị tốc độ hợp lệ duy nhất.
   * Nếu là đường có 2 chiều khác nhau: So khớp với góc La bàn điện thoại (`heading`) hoặc lấy `max(Speed1, Speed2)`.
   * **Cơ chế Fallback 2 lớp:** Nếu đoạn đường không có tốc độ, tự động lấy tốc độ từ Camera/Biển báo gần nhất từ `map_data_points`.
2. **Khi xe di chuyển (`speed \ge 7 km/h`):**
   * Quét bán kính bám làn **$50\text{m}$**.
   * Tính góc tiếp tuyến của **phân đoạn nhỏ $(P_i, P_{i+1})$ gần xe nhất** (Nearest Subsegment Bearing).
   * So sánh với góc di chuyển `GPS Course`, chấp nhận dung sai lệch góc lên đến **$60^\circ$**.

---

## 6. Hướng Dẫn Cập Nhật Dữ Liệu Bản Đồ (1-Click Update Pipeline)

Mỗi khi hãng gửi file `secrect.bin` mới, bạn chỉ cần thực hiện 1 câu lệnh duy nhất:

### Cách 1: Chỉ định trực tiếp đường dẫn file `secrect.bin` mới
```bash
cd /Users/lechaukha12/Desktop/tools/vietdrive
python3 update_pipeline.py --input /duong/dan/toi/secrect.bin
```

### Cách 2: Chép file vào thư mục `map-data/` rồi chạy:
```bash
cd /Users/lechaukha12/Desktop/tools/vietdrive
python3 update_pipeline.py
```

---

## 7. Quy Trình Tự Động Hóa Của Pipeline

Script `update_pipeline.py` sẽ tự động thực hiện tuần tự:
1. **Trích xuất & Giải mã (`extract_all.py`)**: Giải mã S-Box toàn bộ file POI và giải nén LZ77 toàn bộ 4,280 block mạng đường bộ.
2. **Chuẩn hóa & Đóng gói (`normalize.py`)**: Tạo cấu trúc SQLite Schema v6, tạo cây chỉ mục không gian R-Tree 2D và lưu vào `extracted/map_database_v2.sqlite`.
3. **Kiểm tra tính toàn vẹn (Integrity Check)**: Chạy `PRAGMA integrity_check` và xác nhận số lượng bản ghi.
4. **Đồng bộ tự động vào iOS Project**: Sao chép database trực tiếp vào `VietDriveIOS/VietDrive/Resources/map_database_v2.sqlite`.
5. **Chạy Unit Tests**: Đảm bảo toàn bộ 10/10 test case data pipeline và 36/36 test case iOS đều Passed.

---
*Tài liệu được lập bởi Antigravity Reverse Engineering Team.*

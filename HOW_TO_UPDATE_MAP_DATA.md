# 🚀 HƯỚNG DẪN CẬP NHẬT DỮ LIỆU BẢN ĐỒ VIETDRIVE (iOS)
**Quy trình 1-Click Update Database từ file `secrect.bin` mới của hãng**

---

## 📌 BƯỚC 1: Chuẩn Bị File `secrect.bin` Mới

Khi nhận được file `secrect.bin` cập nhật từ hãng:
* Bạn có thể lưu file ở **bất kỳ đâu** trên máy tính (ví dụ: `~/Downloads/secrect.bin`, `Desktop`, hoặc trong thư mục dự án).

---

## ⚡ BƯỚC 2: Chạy Script Cập Nhật Tự Động (Data Pipeline)

Mở **Terminal** và chạy một trong hai cách sau:

### 👉 Cách 1 (Khuyên dùng): Chỉ định trực tiếp đường dẫn tới file mới
```bash
cd /Users/lechaukha12/Desktop/tools/vietdrive
python3 update_pipeline.py --input /duong/dan/toi/file/secrect.bin
```
*(Ví dụ nếu file ở Downloads: `python3 update_pipeline.py --input ~/Downloads/secrect.bin`)*

---

### 👉 Cách 2: Chép đè file vào thư mục `map-data/` rồi chạy
1. Chép file `secrect.bin` mới vào thư mục: `/Users/lechaukha12/Desktop/tools/vietdrive/map-data/secrect.bin`
2. Chạy lệnh:
```bash
cd /Users/lechaukha12/Desktop/tools/vietdrive
python3 update_pipeline.py
```

---

### ⚙️ Những gì hệ thống sẽ tự động thực hiện (Không cần can thiệp):
1. **Giải mã S-Box & Giải nén LZ77 Bitstream**: Trích xuất 100% điểm camera (`edogen.bin`), danh mục tỉnh huyện (`citiesen`, `districtsen`) và toàn bộ mạng lưới đường bộ (`roadsenz.bin`).
2. **Chuẩn hóa SQLite Schema v6**: Xây dựng lại cơ sở dữ liệu `map_database_v2.sqlite` với hệ thống chỉ mục không gian R-Tree 2D.
3. **Kiểm tra tính toàn vẹn**: Tự động thực thi `PRAGMA integrity_check` đảm bảo dữ liệu không lỗi/không hỏng.
4. **Đồng bộ trực tiếp vào iOS App**: Tự động chép đè database mới vào thư mục tài nguyên Xcode: `VietDriveIOS/VietDrive/Resources/map_database_v2.sqlite`.

---

## 📱 BƯỚC 3: Build & Chạy Ứng Dụng iOS

Sau khi script báo `[✓] SUCCESS!`, bạn tiến hành build app:

### 🔹 Cách 1: Sử dụng Xcode (Giao diện trực quan)
1. Mở Xcode project:
   ```bash
   open /Users/lechaukha12/Desktop/tools/vietdrive/VietDriveIOS/VietDrive.xcodeproj
   ```
2. Chọn thiết bị đích: **iPhone của bạn** (cắm cáp/kết nối không dây) hoặc **iOS Simulator (iPhone 16 / iPhone Air)**.
3. Nhấn **`Cmd + R`** (hoặc nút **Play ▶**) để Build và chạy app.

### 🔹 Cách 2: Build nhanh qua Terminal
```bash
cd /Users/lechaukha12/Desktop/tools/vietdrive/VietDriveIOS
xcodebuild -project VietDrive.xcodeproj -scheme VietDrive -destination 'generic/platform=iOS' build
```

---

## 🔍 BƯỚC 4: Kiểm Tra Dữ Liệu Mới Trên App

Sau khi app khởi động:
1. **Kiểm tra HUD / Dashboard:** Khi vừa mở app, tốc độ giới hạn của con đường hiện tại và tên đường sẽ hiển thị ngay tức thì.
2. **Kiểm tra thông số trong màn hình Chẩn đoán:**
   * Mở mục **Cài đặt** $\to$ **Drive Diagnostics (Chẩn đoán)**.
   * Kiểm tra các dòng:
     * *Điểm camera & cảnh báo:* Hiển thị số lượng điểm mới cập nhật.
     * *Mạng lưới đường bộ:* Hiển thị số lượng link đường.
     * *Dataset Timestamp:* Hiển thị thời gian build của file mới.

---
*Tài liệu hướng dẫn phát triển bởi Antigravity Engineering Team.*

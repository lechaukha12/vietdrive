# Quyền riêng tư VietDrive

Cập nhật: 25/08/2026.

VietDrive dùng vị trí chính xác để hiển thị xe, đo tốc độ, tìm cảnh báo gần xe,
dựng tuyến và theo dõi hành trình. Ứng dụng không tạo tài khoản, không dùng mã
quảng cáo và không dùng dữ liệu cho tracking hoặc quảng cáo.

## Dữ liệu rời khỏi thiết bị

Trong bản development 0.3, truy vấn tìm kiếm được gửi tới Photon và tọa độ xuất
phát/đích được gửi tới OSRM qua HTTPS. Các endpoint được khai báo trong
`VietDrive/Support/Info.plist`. VietDrive không gắn các request này với tài
khoản hay định danh quảng cáo.

Camera, biển báo, hạn chế giao thông và lớp đường VietDrive nằm trong SQLite trên thiết
bị. App không tải lịch sử GPS lên máy chủ VietDrive và không lưu lịch sử hành
trình vào database.

Response tìm kiếm/tuyến và tile bản đồ có thể được giữ trong cache của thiết bị
để giảm request và hỗ trợ mở lại dữ liệu gần đây khi mất mạng. Nếu endpoint cập
nhật dữ liệu được cấu hình, app tải manifest và database qua HTTPS rồi kiểm tra
SHA-256 cùng tính toàn vẹn SQLite trước khi kích hoạt.

## Trước khi phát hành

Demo công cộng Photon/OSRM phải được thay bằng instance tự host hoặc nhà cung
cấp có hợp đồng xử lý dữ liệu và chính sách lưu log rõ ràng. Bản chính sách này
phải được xuất bản ở một URL công khai rồi khai báo trong App Store Connect.

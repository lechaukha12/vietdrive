# Voice prompts

Đặt file `.m4a`, `.mp3` hoặc `.wav` vào thư mục này và ánh xạ trong
`manifest.json`. Các key được hỗ trợ:

- `preview`
- `alert.camera`, `alert.speed_limit`, `alert.road_sign`
- `alert.parking_restriction`
- `overspeed`
- `maneuver.left`, `maneuver.right`, `maneuver.uturn`, `maneuver.straight`
- `arrival`

Nếu thiếu file, app tự động dùng giọng tiếng Việt của iOS. Cảnh báo cấm rẽ là
ngoại lệ: chỉ hiển thị trên bản đồ khi đang dẫn đường và luôn im lặng.

`baseDirectory` có thể trỏ tới một folder reference được đóng gói nguyên thư mục.
Bộ `VoicePacks/south_female_1` hiện chỉ dùng tạm cho development; không đưa
vào bản phát hành trước khi xác nhận quyền sử dụng/phân phối.

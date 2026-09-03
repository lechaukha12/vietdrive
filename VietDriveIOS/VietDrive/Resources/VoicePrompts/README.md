# Voice prompts

## Bộ đang dùng

**Adam · Nam miền Nam**, gồm 107 MP3 tại `VoicePacks/south_male_adam`.
Nguồn: bộ `output_vietdrive_voices/south_male_adam` do chủ dự án cung cấp.
Bộ nữ miền Nam cũ đã được thay thế, không còn đóng gói trong app.

`manifest.json` schema 2 định nghĩa `voiceName`, `baseDirectory` và ánh xạ
`prompts` (104 key → 104 file). Giữ nguyên tên file khi thay bản thu. Xcode đóng
gói MP3 dưới dạng resource; `RecordedVoiceCatalog` hỗ trợ cả thư mục pack và
resource phẳng trong bundle. `project.yml` tự quét thư mục resource hiện tại.

`checksums.json` trong pack ghi `bytes`, `md5`, `sha256` cho đủ 107 file nguồn.
Cập nhật checksum khi thay âm thanh. Unit test kiểm tra checksum và khả năng
giải mã của toàn bộ file được manifest tham chiếu.

## Các nhóm key

- `preview`, `gps.found`, `gps.lost`, `overspeed`, `reroute`.
- `arrival`, `arrival.left`, `arrival.right`.
- `speed.next.{30,40,50,60,70,80,90,100,120}`.
- `maneuver.{300,now}.{left,right,sharp_left,sharp_right,slight_left,slight_right,straight,uturn}`.
- `maneuver.{300,now}.roundabout.{1...9}`.
- `alert.camera`, `alert.camera.speed`, `alert.camera.traffic`,
  `alert.camera.section`, `alert.camera.dual`.
- `alert.town.in`, `alert.town.out`, `alert.overtaking.in`, `alert.overtaking.out`.
- `alert.tunnel`, `alert.railway`, `alert.rest_area`, `alert.toll`, `alert.checkpoint`.
- `alert.sign.{code}` cho 27 biển cấm, hiệu lệnh và cảnh báo còn lại.
- `alert.generic`, `speed.generic`, `maneuver.generic` là các câu Adam dự phòng.

Chín key `speed.current.*` được giữ sẵn cho cảnh báo tốc độ hiện tại.
Ba file chưa có key: `tram_dung_cao_toc.mp3`,
`under_min_speed.mp3`, `tpms_error.mp3`. Thay bộ voice không tự kích hoạt các câu này.

## Chính sách phát voice

- `preview` và camera đo tốc độ theo đoạn có file Adam riêng.
- `camera_ai.mp3` chỉ dùng cho camera kép tốc độ + đèn tín hiệu.
- Không có nhánh TTS iOS. Nếu resource bị thiếu/hỏng, app ghi chẩn đoán và bỏ
  qua câu đó thay vì đổi giọng giữa hành trình.
- Cảnh báo `kind == .turnRestriction` (quy tắc suy luận) im lặng. Biển vật lý
  không tự động bị giữ im lặng chỉ vì có mã cấm rẽ.
- Nhóm `300_*` nói mốc 300 m; logic hiện tại gọi khi còn trên 80 m và không quá
  360 m, nhóm `now` khi còn không quá 80 m. Việc thay pack không đổi ngưỡng này.

Xác nhận quyền sử dụng/phân phối bộ giọng mới trước khi phát hành.

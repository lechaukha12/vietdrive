# Voice prompts

## Bộ đang dùng

**Adam · Nam miền Nam**, gồm 75 MP3 tại `VoicePacks/south_male_adam`.
Nguồn: bộ `output_vietdrive_voices/south_male_adam` do chủ dự án cung cấp.
Bộ nữ miền Nam cũ đã được thay thế, không còn đóng gói trong app.

`manifest.json` schema 2 định nghĩa `voiceName`, `baseDirectory` và ánh xạ
`prompts` (73 key → 72 file). Giữ nguyên tên file khi thay bản thu. Xcode đóng
gói MP3 dưới dạng resource; `RecordedVoiceCatalog` hỗ trợ cả thư mục pack và
resource phẳng trong bundle. `project.yml` tự quét thư mục resource hiện tại.

`checksums.json` trong pack ghi `bytes`, `md5`, `sha256` cho đủ 75 file nguồn.
Cập nhật checksum khi thay âm thanh. Unit test kiểm tra checksum và khả năng
giải mã của toàn bộ file được manifest tham chiếu.

## Các nhóm key

- `preview`, `gps.found`, `gps.lost`, `overspeed`, `reroute`.
- `arrival`, `arrival.left`, `arrival.right`.
- `speed.next.{30,40,50,60,70,80,90,100,120}`.
- `maneuver.{300,now}.{left,right,sharp_left,sharp_right,slight_left,slight_right,straight,uturn}`.
- `maneuver.{300,now}.roundabout.{1...9}`.
- `alert.camera`, `alert.camera.traffic`, `alert.camera.dual`.
- `alert.town.in`, `alert.town.out`, `alert.overtaking.in`, `alert.overtaking.out`.
- `alert.tunnel`, `alert.railway`, `alert.rest_area`, `alert.toll`, `alert.checkpoint`.

Đã khai báo nhưng chưa được luồng hiện tại gọi: `alert.camera.speed` và 9 key
`speed.current.*`. Ba file chưa có key: `tram_dung_cao_toc.mp3`,
`under_min_speed.mp3`, `tpms_error.mp3`. Thay bộ voice không tự kích hoạt các câu này.

## Nội dung chưa có file riêng

- `preview` vẫn dùng chung `gps_signal_found.mp3` với `gps.found`.
- **Không ánh xạ `alert.camera.section` tới `camera_ai.mp3`:** kịch bản Adam
  của file này là “Phía trước có camera giám sát tốc độ và đèn tín hiệu.”,
  không phải camera đo tốc độ theo đoạn. Giữ TTS hiện có cho camera theo đoạn;
  chỉ thêm mapping khi có bản thu đúng nội dung.
- Các biển cấm/hiệu lệnh và câu động chưa có MP3 tiếp tục dùng TTS iOS.
- Cảnh báo `kind == .turnRestriction` (quy tắc suy luận) im lặng. Biển vật lý
  không tự động bị giữ im lặng chỉ vì có mã cấm rẽ.
- Nhóm `300_*` nói mốc 300 m; logic hiện tại gọi khi còn trên 80 m và không quá
  360 m, nhóm `now` khi còn không quá 80 m. Việc thay pack không đổi ngưỡng này.

Xác nhận quyền sử dụng/phân phối bộ giọng mới trước khi phát hành.

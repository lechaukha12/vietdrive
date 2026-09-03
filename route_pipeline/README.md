# VietDrive Route Demo Pipeline

Pipeline này hỗ trợ xây dựng và kiểm thử dữ liệu lộ trình chạy thử offline (Demo Mode) TP.HCM → Phan Thiết.

Lộ trình thực tế được ứng dụng iOS tiêu thụ hiện tại nằm tại:
`VietDriveIOS/VietDrive/Resources/Demo/saigon-phanthiet.json` (Schema v1, 1.263 tọa độ, 168,3 km, gồm danh sách chỉ dẫn rẽ `steps`).

## Chạy Kiểm Thử Fixture

```bash
python3 -m unittest discover -s route_pipeline -v
```

Bộ test kiểm tra:
1. Tính liên tục, đơn điệu và cự ly (>160 km) của lộ trình TP.HCM → Phan Thiết.
2. Thứ tự hợp lệ của các bước chỉ dẫn rẽ (`steps`).
3. Mọi biển báo được công bố trong `extracted/osm_traffic_signs.geojson` đều có file asset tương ứng trong `traffic_sign_assets/manifest.json`.
4. Không công bố các thẻ biển báo mơ hồ (`traffic_sign=yes`).
5. Đầy đủ các biển báo trọng yếu (P102, P103c, P122, P130, W208).

## Tái tạo Fixture Lộ trình

```bash
python3 build_demo.py
```

*Lưu ý:* Các endpoint công cộng (OSRM, Overpass) chỉ sử dụng trong môi trường phát triển (development/testing). Trước khi phát hành ứng dụng thực tế, VietDrive cần tự host các dịch vụ OSRM/Valhalla hoặc sử dụng nhà cung cấp có SLA chính thức.

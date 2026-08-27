# VietDrive OSM restriction pipeline

Pipeline này trích xuất hai nhóm dữ liệu độc lập từ snapshot OSM Việt Nam:

- Quan hệ `type=restriction`: cấm rẽ, cấm quay đầu và các restriction có điều kiện.
- Quy tắc trên đường: `oneway`, `access`, hạn chế phương tiện, giới hạn tốc độ có
  điều kiện và các tag `parking:*`.

Kết quả không được coi là danh mục pháp lý đầy đủ. Bản ghi thiếu nút `via`, có
restriction không nhận dạng được hoặc geometry không hợp lệ được đưa vào hàng
chờ kiểm duyệt thay vì công bố.

```sh
../sign_pipeline/.venv/bin/python -m unittest -v
../sign_pipeline/.venv/bin/python build_restrictions.py
```

Outputs:

- `extracted/osm_turn_restrictions.geojson`
- `extracted/osm_road_rules.geojson`
- `extracted/osm_restriction_quarantine.json`
- `restriction_pipeline/restriction_report.json`


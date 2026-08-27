# VietDrive nationwide traffic-sign pipeline

This pipeline extracts physical sign nodes from the Geofabrik Vietnam OSM PBF.
The large PBF stays in `cache/` and is never bundled into the iOS app. Published
features must have a recognized code and a matching candidate asset. Generic
`traffic_sign=yes` remains reported but is not published.

```sh
python3 -m venv .venv
.venv/bin/pip install osmium
curl -fL -o cache/vietnam-latest.osm.pbf \
  https://download.geofabrik.de/asia/vietnam-latest.osm.pbf
.venv/bin/python -m unittest -v
.venv/bin/python build_signs.py
```

Outputs:

- `extracted/osm_traffic_signs.geojson`
- `extracted/osm_sign_quarantine.json` (hàng chờ kiểm duyệt, không bundle vào app)
- `sign_pipeline/sign_report.json`

The report distinguishes raw physical-sign nodes, recognized/published nodes,
and unrecognized values. OSM coverage is community-contributed and incomplete;
the pipeline must never describe it as a complete legal inventory.

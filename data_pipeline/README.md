# VietDrive data pipeline

This directory contains the deterministic quality gate between the recovered
source data and the iOS application.

Run from this directory:

    python3 -m unittest -v
    python3 normalize.py

The pipeline writes map_database_v2.sqlite to the extracted directory and
quality reports to data_pipeline/reports. The application database includes
source hashes and raw camera attributes for traceability.

Schema v4 adds `map_data_points` as the active business overlay while retaining
the previous normalized tables for audit and migration compatibility. The base
map and navigation route remain MapLibre layers. `map_data_points` is imported
from the iGO `X,Y,TYPE,SPEED,DIRTYPE,DIRECTION` records in
`map-data/extracted_data/csv/cities.csv`.
`extracted/data_manifest.json` records checksums and counts for reproducible updates.

To create a manifest for a hosted release:

    python3 package_release.py --database-url https://data.example/map_database_v2.sqlite

Current publication rules:

- Publish every valid point from `map-data`; preserve its numeric iGO type,
  speed, direction mode, normalized direction, raw direction and source ID.
- Normalize the archive's encoded direction range 500-559 back to 300-359.
- Use map-data type 1 as the app's only source for displayed/enforced speed;
  OSM maxspeed and recovered road estimates remain audit-only.

- Merge camera positions within 3 metres.
- Reject camera positions outside practical mainland Vietnam bounds.
- Accept road geometry only when every edge is at most 2 km and total length is
  at most 20 km.
- Keep recovered speed points as reference observations, not verified signs.
- Publish only recognized OpenStreetMap traffic-sign codes that have a matching
  app asset; ignore generic `traffic_sign=yes` records.
- Keep unrecognized signs and malformed restrictions in explicit review queues.
- Store physical signs separately from turn restrictions and road-level rules.
- Quarantine the entire toll layer because the source marks every road as toll.
- Preserve source province labels for audit only; never show them as authoritative.

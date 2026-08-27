# VietDrive data quality report

Generated: 2026-08-27T03:55:27+00:00

## Production result

- Database integrity: ok
- map-data points published: 36820
- map-data speed-camera points: 16400
- map-data raw directions left uninterpreted (>359): 0
- map-data directional road links published: 1875900
- map-data road links with a non-zero raw directional value: 1875900
- map-data road links with a display-supported directional speed: 1875812
- raw directional values preserved without conversion: True
- unverified road names preserved as raw hex in quarantine: 0
- map-data road links quarantined: 0
- Camera source points: 3892
- Camera production clusters: 3603
- Camera points merged as near-duplicates: 160
- Camera points outside bounds: 129
- Road source segments: 5517
- Road segments accepted: 791
- Accepted roads with known speed: 329
- Road segments quarantined: 4726
- Speed observations retained for reference only: 2049
- Recognized OSM traffic signs published: 134
- OSM traffic signs quarantined: 688
- OSM turn restrictions published: 1659
- OSM turn restrictions quarantined: 1853
- OSM road-rule ways published: 135125
- Toll records published: 0

## Policy

Every decoded directional byte from map-data/roadsenz.bin is retained exactly.
The active app only displays literal speed values in the explicit supported
set; it does not convert or infer other values. map-data/edogen.bin supplies upcoming iGO points using
X,Y,TYPE,SPEED,DIRTYPE,DIRECTION. The retained legacy/OSM layers remain audit
data and do not override the provider road graph. Invalid graph coordinates are
quarantined. The toll layer is quarantined because every legacy road was
flagged as a toll road.

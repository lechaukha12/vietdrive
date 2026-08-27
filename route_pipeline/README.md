# VietDrive route demo pipeline

This pipeline fetches the shortest TP.HCM to Phan Thiet alternative returned by
the public OSRM demo service, then queries OpenStreetMap tags through Overpass.
It builds a full-resolution route, maneuver list, speed profile and a curated
traffic-sign overlay.

Run:

    python3 build_demo.py

Only explicit, recognized traffic-sign tags are published. Generic
traffic_sign=yes records are intentionally ignored. Speed points sourced from
OSM maxspeed are marked osm_maxspeed; missing coverage uses a visibly recorded
fallback and must not be treated as a verified legal limit.

Public endpoints are suitable for rebuilding development fixtures, not for
production navigation. VietDrive should self-host OSRM/Valhalla and Overpass or
use a contracted provider before release.

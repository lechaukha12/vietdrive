#!/usr/bin/env python3
"""Build VietDrive's reproducible, quality-gated offline map database."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "extracted"
MAP_DATA_DIR = ROOT / "map-data" / "extracted_data"
REPORT_DIR = Path(__file__).resolve().parent / "reports"
DEFAULT_OUTPUT = SOURCE_DIR / "map_database_v2.sqlite"
DATABASE_CONTRACT_ID = "vn.vietdrive.map-data"
DATABASE_CONTRACT_VERSION = 1
DATABASE_SCHEMA_VERSION = 6

VIETNAM_MAINLAND_BOUNDS = (8.15, 23.50, 102.00, 109.60)
CAMERA_MERGE_METERS = 3.0
MAX_ROAD_EDGE_METERS = 2_000.0
MAX_ROAD_LENGTH_METERS = 20_000.0
VALID_SPEEDS = {0, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120}

# edogen.bin follows the iGO speed-camera interchange format:
# X, Y, TYPE, SPEED, DIRTYPE, DIRECTION. Keep the numeric type in SQLite so a
# future client can add richer presentation without re-extracting the archive.
MAP_DATA_TYPE_INFO = {
    1: ("speed_camera", "Camera tốc độ"),
    2: ("traffic_light_camera", "Camera đèn tín hiệu"),
    4: ("section_camera", "Camera đo tốc độ theo đoạn"),
    10: ("town_entry", "Điểm vào khu dân cư"),
    11: ("red_light_speed_camera", "Camera đèn đỏ và tốc độ"),
}


@dataclass(frozen=True)
class CameraSource:
    source_id: int
    latitude: float
    longitude: float
    raw_attributes: str


@dataclass(frozen=True)
class CameraCluster:
    latitude: float
    longitude: float
    source_ids: tuple[int, ...]
    raw_attributes: tuple[str, ...]


@dataclass(frozen=True)
class RoadResult:
    source_segment_id: int
    road_id: int
    speed_kmh: int
    source_province: str
    coordinates: tuple[tuple[float, float], ...]
    length_meters: float
    max_edge_meters: float
    accepted: bool
    reason: str


@dataclass(frozen=True)
class MapDataPoint:
    source_node_id: int
    longitude: float
    latitude: float
    type_code: int
    kind: str
    speed_kmh: int
    direction_type: int
    direction_degrees: int | None
    raw_direction: int
    warning_text: str


@dataclass(frozen=True)
class MapDataRoadLink:
    road_serial_number: int
    provider_road_id: int
    inline_road_name: str
    direction_1_name_id: int
    direction_2_name_id: int
    direction_1_speed_kmh: int
    direction_2_speed_kmh: int
    coordinates: tuple[tuple[float, float], ...]


def normalize_igo_direction(value: int) -> int | None:
    """Accept only a literal compass bearing; never infer encoded values."""
    return value if 0 <= value <= 359 else None


def load_map_data_points(path: Path) -> tuple[list[MapDataPoint], list[dict]]:
    """Load every exactly decoded edogen point."""
    points: list[MapDataPoint] = []
    issues: list[dict] = []
    with path.open(encoding="utf-8-sig", newline="") as handle:
        for index, row in enumerate(csv.DictReader(handle), start=1):
            source_id = int(row.get("node_id") or index)
            try:
                longitude = float(row["longitude"])
                latitude = float(row["latitude"])
                type_code = int(row["type"])
                speed = int(row["speed_limit"])
                direction_type = int(row["direction_type"])
                raw_direction = int(row["raw_direction"])
            except (KeyError, TypeError, ValueError):
                issues.append({
                    "dataset": "map_data_point",
                    "source_id": source_id,
                    "reason": "invalid_record",
                    "row": row,
                })
                continue
            # This source includes border-adjacent points beyond the narrower
            # mainland quality gate used by the legacy recovered layers.
            if not (8.0 <= latitude <= 25.5 and 102.0 <= longitude <= 110.5):
                issues.append({
                    "dataset": "map_data_point",
                    "source_id": source_id,
                    "reason": "invalid_coordinate",
                    "latitude": latitude,
                    "longitude": longitude,
                })
                continue
            if speed not in VALID_SPEEDS:
                issues.append({
                    "dataset": "map_data_point",
                    "source_id": source_id,
                    "reason": "unsupported_speed",
                    "speed_kmh": speed,
                })
                speed = 0
            kind, label = MAP_DATA_TYPE_INFO.get(
                type_code, (f"igo_type_{type_code}", f"Dữ liệu giao thông loại {type_code}")
            )
            direction = normalize_igo_direction(raw_direction)
            points.append(MapDataPoint(
                source_node_id=source_id,
                longitude=longitude,
                latitude=latitude,
                type_code=type_code,
                kind=kind,
                speed_kmh=speed,
                direction_type=direction_type,
                direction_degrees=direction,
                raw_direction=raw_direction,
                warning_text=(
                    f"{label} · giới hạn {speed} km/h" if speed > 0 else label
                ),
            ))
    return points, issues


def iter_map_data_road_links(path: Path):
    """Stream all directional links decoded from the M1 roadsenz graph."""
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.reader(handle)
        next(reader, None)
        for row_number, row in enumerate(reader, start=2):
            source_id = row_number - 1
            try:
                road_serial_number = int(row[0])
                provider_road_id = int(row[1])
                inline_road_name = row[2]
                direction_1_name_id = int(row[3])
                direction_2_name_id = int(row[4])
                direction_1_speed = int(row[5])
                direction_2_speed = int(row[6])
                raw_coordinates = row[7:]
                if len(raw_coordinates) < 4 or len(raw_coordinates) % 2:
                    raise ValueError("invalid coordinate pair count")
                coordinates = tuple(
                    (float(raw_coordinates[index]), float(raw_coordinates[index + 1]))
                    for index in range(0, len(raw_coordinates), 2)
                )
            except (IndexError, TypeError, ValueError) as error:
                yield None, {
                    "dataset": "map_data_road_link",
                    "source_id": source_id,
                    "reason": "invalid_record",
                    "error": str(error),
                    "row_number": row_number,
                }
                continue

            if any(not 0 <= speed <= 255 for speed in (direction_1_speed, direction_2_speed)):
                yield None, {
                    "dataset": "map_data_road_link",
                    "source_id": source_id,
                    "reason": "invalid_directional_speed_byte",
                    "direction_1_speed_kmh": direction_1_speed,
                    "direction_2_speed_kmh": direction_2_speed,
                }
                continue
            if any(
                not (8.0 <= latitude <= 25.7 and 101.8 <= longitude <= 110.7)
                for longitude, latitude in coordinates
            ):
                yield None, {
                    "dataset": "map_data_road_link",
                    "source_id": source_id,
                    "reason": "invalid_coordinate",
                }
                continue

            yield MapDataRoadLink(
                road_serial_number=road_serial_number,
                provider_road_id=provider_road_id,
                inline_road_name=inline_road_name,
                direction_1_name_id=direction_1_name_id,
                direction_2_name_id=direction_2_name_id,
                direction_1_speed_kmh=direction_1_speed,
                direction_2_speed_kmh=direction_2_speed,
                coordinates=coordinates,
            ), None


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_exact_lookup(path: Path, field_names: tuple[str, ...]) -> list[tuple]:
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if tuple(reader.fieldnames or ()) != field_names:
            raise ValueError(f"Unexpected lookup schema in {path}: {reader.fieldnames}")
        return [tuple(row[field] for field in field_names) for row in reader]


def haversine_meters(a_lat: float, a_lon: float, b_lat: float, b_lon: float) -> float:
    radius = 6_371_008.8
    phi1, phi2 = math.radians(a_lat), math.radians(b_lat)
    d_phi = math.radians(b_lat - a_lat)
    d_lambda = math.radians(b_lon - a_lon)
    h = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )
    return 2 * radius * math.asin(min(1.0, math.sqrt(h)))


def in_mainland_bounds(latitude: float, longitude: float) -> bool:
    min_lat, max_lat, min_lon, max_lon = VIETNAM_MAINLAND_BOUNDS
    return min_lat <= latitude <= max_lat and min_lon <= longitude <= max_lon


def load_geojson(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        payload = json.load(handle)
    if payload.get("type") != "FeatureCollection":
        raise ValueError(f"{path.name} is not a GeoJSON FeatureCollection")
    return payload.get("features", [])


def load_quarantine(path: Path, dataset: str) -> list[dict]:
    if not path.exists():
        return []
    payload = json.loads(path.read_text(encoding="utf-8"))
    return [
        {
            "dataset": dataset,
            "source_id": record.get("osm_id"),
            "reason": str(record.get("reason") or "pending_review"),
            **record,
        }
        for record in payload.get("records", [])
    ]


def load_cameras(path: Path) -> tuple[list[CameraSource], list[dict]]:
    accepted: list[CameraSource] = []
    issues: list[dict] = []
    for index, feature in enumerate(load_geojson(path), start=1):
        props = feature.get("properties") or {}
        coords = (feature.get("geometry") or {}).get("coordinates") or []
        source_id = int(props.get("id") or index)
        try:
            longitude, latitude = float(coords[0]), float(coords[1])
        except (IndexError, TypeError, ValueError):
            issues.append({"dataset": "camera", "source_id": source_id, "reason": "invalid_coordinate"})
            continue
        if not in_mainland_bounds(latitude, longitude):
            issues.append({
                "dataset": "camera",
                "source_id": source_id,
                "reason": "outside_mainland_bounds",
                "latitude": latitude,
                "longitude": longitude,
            })
            continue
        accepted.append(CameraSource(
            source_id=source_id,
            latitude=latitude,
            longitude=longitude,
            raw_attributes=str(props.get("attributes") or ""),
        ))
    return accepted, issues


def _camera_cell(camera: CameraSource, cell_meters: float) -> tuple[int, int]:
    lat_step = cell_meters / 111_320.0
    lon_step = cell_meters / (111_320.0 * max(0.1, math.cos(math.radians(camera.latitude))))
    return int(math.floor(camera.latitude / lat_step)), int(math.floor(camera.longitude / lon_step))


def cluster_cameras(cameras: Sequence[CameraSource], radius_meters: float) -> list[CameraCluster]:
    if not cameras:
        return []
    parent = list(range(len(cameras)))

    def find(value: int) -> int:
        while parent[value] != value:
            parent[value] = parent[parent[value]]
            value = parent[value]
        return value

    def union(left: int, right: int) -> None:
        left_root, right_root = find(left), find(right)
        if left_root != right_root:
            parent[right_root] = left_root

    buckets: dict[tuple[int, int], list[int]] = {}
    for index, camera in enumerate(cameras):
        cell = _camera_cell(camera, radius_meters)
        for row_offset in (-1, 0, 1):
            for column_offset in (-1, 0, 1):
                for other_index in buckets.get((cell[0] + row_offset, cell[1] + column_offset), []):
                    other = cameras[other_index]
                    if haversine_meters(
                        camera.latitude,
                        camera.longitude,
                        other.latitude,
                        other.longitude,
                    ) <= radius_meters:
                        union(index, other_index)
        buckets.setdefault(cell, []).append(index)

    groups: dict[int, list[CameraSource]] = {}
    for index, camera in enumerate(cameras):
        groups.setdefault(find(index), []).append(camera)

    result = []
    for group in groups.values():
        result.append(CameraCluster(
            latitude=sum(item.latitude for item in group) / len(group),
            longitude=sum(item.longitude for item in group) / len(group),
            source_ids=tuple(sorted(item.source_id for item in group)),
            raw_attributes=tuple(item.raw_attributes for item in sorted(group, key=lambda item: item.source_id)),
        ))
    return sorted(result, key=lambda item: item.source_ids[0])


def validate_roads(path: Path) -> list[RoadResult]:
    results: list[RoadResult] = []
    for index, feature in enumerate(load_geojson(path), start=1):
        props = feature.get("properties") or {}
        segment_id = int(props.get("segment_id") or index)
        road_id = int(props.get("road_id") or 0)
        speed = int(props.get("speed_kmh") or 0)
        province = str(props.get("province") or "")
        raw_coords = (feature.get("geometry") or {}).get("coordinates") or []
        try:
            coordinates = tuple((float(point[0]), float(point[1])) for point in raw_coords)
        except (IndexError, TypeError, ValueError):
            coordinates = ()

        reason = ""
        edge_lengths: list[float] = []
        if len(coordinates) < 2:
            reason = "insufficient_geometry"
        elif speed not in VALID_SPEEDS:
            reason = "invalid_speed"
        elif any(not in_mainland_bounds(lat, lon) for lon, lat in coordinates):
            reason = "outside_mainland_bounds"
        else:
            edge_lengths = [
                haversine_meters(a_lat, a_lon, b_lat, b_lon)
                for (a_lon, a_lat), (b_lon, b_lat) in zip(coordinates, coordinates[1:])
            ]
            if max(edge_lengths, default=0.0) > MAX_ROAD_EDGE_METERS:
                reason = "implausible_edge"
            elif sum(edge_lengths) > MAX_ROAD_LENGTH_METERS:
                reason = "implausible_total_length"

        total_length = sum(edge_lengths)
        results.append(RoadResult(
            source_segment_id=segment_id,
            road_id=road_id,
            speed_kmh=speed,
            source_province=province,
            coordinates=coordinates,
            length_meters=total_length,
            max_edge_meters=max(edge_lengths, default=0.0),
            accepted=not reason,
            reason=reason or "accepted",
        ))
    return results


def load_speed_observations(path: Path) -> list[dict]:
    observations = []
    for index, feature in enumerate(load_geojson(path), start=1):
        props = feature.get("properties") or {}
        if props.get("type") != "speed_limit":
            continue
        coords = (feature.get("geometry") or {}).get("coordinates") or []
        try:
            longitude, latitude = float(coords[0]), float(coords[1])
            speed = int(props.get("speed_kmh") or 0)
        except (IndexError, TypeError, ValueError):
            continue
        if in_mainland_bounds(latitude, longitude) and speed in VALID_SPEEDS and speed > 0:
            observations.append({
                "source_id": index,
                "road_id": int(props.get("road_id") or 0),
                "speed_kmh": speed,
                "latitude": latitude,
                "longitude": longitude,
                "source_province": str(props.get("province") or ""),
            })
    return observations


def load_osm_traffic_signs(path: Path) -> tuple[list[dict], list[dict]]:
    if not path.exists():
        return [], []
    signs = []
    issues = []
    for feature in load_geojson(path):
        props = feature.get("properties") or {}
        coords = (feature.get("geometry") or {}).get("coordinates") or []
        source_id = props.get("osm_id")
        try:
            longitude, latitude = float(coords[0]), float(coords[1])
        except (IndexError, TypeError, ValueError):
            issues.append({
                "dataset": "osm_traffic_sign",
                "source_id": source_id,
                "reason": "invalid_coordinate",
            })
            continue
        sign_code = str(props.get("sign_code") or "")
        asset_name = str(props.get("asset_name") or "")
        if not in_mainland_bounds(latitude, longitude):
            issues.append({
                "dataset": "osm_traffic_sign",
                "source_id": source_id,
                "reason": "outside_mainland_bounds",
            })
            continue
        if not sign_code or not asset_name:
            issues.append({
                "dataset": "osm_traffic_sign",
                "source_id": source_id,
                "reason": "unknown_sign",
            })
            continue
        speed_match = re.search(r"P127\.(\d+)", sign_code)
        direction_text = str(props.get("direction") or "").strip()
        direction_match = re.search(r"-?\d+(?:\.\d+)?", direction_text)
        signs.append({
            "source_id": int(source_id),
            "source_type": str(props.get("osm_type") or ""),
            "latitude": latitude,
            "longitude": longitude,
            "sign_code": sign_code,
            "asset_name": asset_name,
            "warning_text": str(props.get("warning_text") or "Biển báo giao thông"),
            "speed_kmh": int(speed_match.group(1)) if speed_match else 0,
            "source_ref": str(props.get("osm_url") or ""),
            "direction_scope": str(props.get("direction_scope") or "unknown"),
            "direction_degrees": (
                float(direction_match.group()) % 360 if direction_match else None
            ),
            "conditional": str(props.get("conditional") or ""),
            "confidence": float(props.get("confidence") or 0.82),
            "review_status": str(props.get("review_status") or "normalized"),
            "raw_tags": props.get("tags") or {},
        })
    return signs, issues


def load_osm_turn_restrictions(path: Path) -> tuple[list[dict], list[dict]]:
    if not path.exists():
        return [], []
    restrictions = []
    issues = []
    for feature in load_geojson(path):
        props = feature.get("properties") or {}
        coords = (feature.get("geometry") or {}).get("coordinates") or []
        source_id = props.get("osm_id")
        try:
            longitude, latitude = float(coords[0]), float(coords[1])
            from_way_id = int(props["from_way_id"])
            to_way_id = int(props["to_way_id"])
            via_node_id = int(props["via_node_id"])
        except (IndexError, KeyError, TypeError, ValueError):
            issues.append({
                "dataset": "osm_turn_restriction",
                "source_id": source_id,
                "reason": "invalid_restriction",
            })
            continue
        if not in_mainland_bounds(latitude, longitude):
            issues.append({
                "dataset": "osm_turn_restriction",
                "source_id": source_id,
                "reason": "outside_mainland_bounds",
            })
            continue
        restrictions.append({
            "source_id": int(source_id),
            "latitude": latitude,
            "longitude": longitude,
            "restriction": str(props.get("restriction") or ""),
            "warning_text": str(props.get("warning_text") or "Hạn chế giao thông"),
            "vehicle": str(props.get("vehicle") or "motor_vehicle"),
            "conditional": str(props.get("conditional") or ""),
            "except": str(props.get("except") or ""),
            "from_way_id": from_way_id,
            "to_way_id": to_way_id,
            "via_node_id": via_node_id,
            "source_ref": str(props.get("osm_url") or ""),
            "confidence": float(props.get("confidence") or 0.80),
            "review_status": str(props.get("review_status") or "normalized"),
            "raw_tags": props.get("tags") or {},
        })
    return restrictions, issues


def load_osm_road_rules(path: Path) -> tuple[list[dict], list[dict]]:
    if not path.exists():
        return [], []
    rules = []
    issues = []
    for feature in load_geojson(path):
        props = feature.get("properties") or {}
        raw_coords = (feature.get("geometry") or {}).get("coordinates") or []
        source_id = props.get("way_id")
        try:
            coordinates = tuple((float(point[0]), float(point[1])) for point in raw_coords)
            way_id = int(source_id)
        except (IndexError, TypeError, ValueError):
            coordinates = ()
            way_id = 0
        if len(coordinates) < 2:
            issues.append({
                "dataset": "osm_road_rule",
                "source_id": source_id,
                "reason": "invalid_geometry",
            })
            continue
        if any(not in_mainland_bounds(lat, lon) for lon, lat in coordinates):
            issues.append({
                "dataset": "osm_road_rule",
                "source_id": source_id,
                "reason": "outside_mainland_bounds",
            })
            continue
        rules.append({
            "way_id": way_id,
            "rules": {
                str(key): str(value)
                for key, value in (props.get("rules") or {}).items()
            },
            "road_name": str(props.get("road_name") or ""),
            "highway": str(props.get("highway") or ""),
            "coordinates": coordinates,
            "source_ref": str(props.get("osm_url") or ""),
            "confidence": float(props.get("confidence") or 0.82),
            "review_status": str(props.get("review_status") or "normalized"),
            "raw_tags": props.get("tags") or {},
        })
    return rules, issues


def create_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        PRAGMA journal_mode = DELETE;
        PRAGMA foreign_keys = ON;
        PRAGMA user_version = 6;

        CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE alerts (
            id INTEGER PRIMARY KEY,
            type TEXT NOT NULL CHECK(type IN ('camera', 'road_sign')),
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            warning_text TEXT NOT NULL,
            speed_kmh INTEGER NOT NULL DEFAULT 0,
            sign_code TEXT,
            asset_name TEXT,
            source TEXT NOT NULL,
            source_ref TEXT,
            confidence REAL NOT NULL CHECK(confidence BETWEEN 0 AND 1),
            cluster_size INTEGER NOT NULL,
            source_ids_json TEXT NOT NULL,
            raw_attributes_json TEXT NOT NULL,
            direction_scope TEXT NOT NULL DEFAULT 'unknown',
            direction_degrees REAL,
            conditional TEXT NOT NULL DEFAULT '',
            source_updated_at TEXT NOT NULL,
            review_status TEXT NOT NULL DEFAULT 'normalized'
        );
        CREATE VIRTUAL TABLE alerts_rtree USING rtree(
            alert_id, min_lat, max_lat, min_lon, max_lon
        );

        CREATE TABLE map_data_points (
            id INTEGER PRIMARY KEY,
            source_node_id INTEGER NOT NULL UNIQUE,
            type_code INTEGER NOT NULL,
            kind TEXT NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            speed_kmh INTEGER NOT NULL DEFAULT 0,
            direction_type INTEGER NOT NULL DEFAULT 0,
            direction_degrees REAL,
            raw_direction INTEGER NOT NULL,
            warning_text TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'map-data/edogen.bin',
            source_ref TEXT NOT NULL,
            confidence REAL NOT NULL CHECK(confidence BETWEEN 0 AND 1)
        );
        CREATE VIRTUAL TABLE map_data_points_rtree USING rtree(
            point_id, min_lat, max_lat, min_lon, max_lon
        );

        CREATE TABLE map_data_city_lookup (
            id INTEGER PRIMARY KEY,
            label TEXT NOT NULL
        );

        CREATE TABLE map_data_name_lookup (
            id INTEGER PRIMARY KEY,
            city_id INTEGER NOT NULL,
            label TEXT NOT NULL
        );

        CREATE TABLE map_data_road_links (
            id INTEGER PRIMARY KEY,
            road_serial_number INTEGER NOT NULL UNIQUE,
            provider_road_id INTEGER NOT NULL,
            inline_road_name TEXT NOT NULL,
            direction_1_name_id INTEGER NOT NULL,
            direction_2_name_id INTEGER NOT NULL,
            direction_1_speed_kmh INTEGER NOT NULL,
            direction_2_speed_kmh INTEGER NOT NULL,
            geometry_json TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'map-data/roadsenz.bin',
            confidence REAL NOT NULL CHECK(confidence BETWEEN 0 AND 1)
        );
        CREATE VIRTUAL TABLE map_data_road_links_rtree USING rtree(
            link_id, min_lat, max_lat, min_lon, max_lon
        );

        CREATE TABLE road_segments (
            id INTEGER PRIMARY KEY,
            source_segment_id INTEGER NOT NULL UNIQUE,
            road_id INTEGER NOT NULL,
            speed_kmh INTEGER NOT NULL,
            length_meters REAL NOT NULL,
            source_province TEXT NOT NULL,
            geometry_json TEXT NOT NULL,
            quality TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE road_segments_rtree USING rtree(
            segment_id, min_lat, max_lat, min_lon, max_lon
        );

        CREATE TABLE speed_observations (
            id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL,
            road_id INTEGER NOT NULL,
            speed_kmh INTEGER NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            source_province TEXT NOT NULL,
            usage TEXT NOT NULL CHECK(usage = 'reference_only')
        );

        CREATE TABLE turn_restrictions (
            id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL UNIQUE,
            restriction TEXT NOT NULL,
            warning_text TEXT NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            from_way_id INTEGER NOT NULL,
            to_way_id INTEGER NOT NULL,
            via_node_id INTEGER NOT NULL,
            vehicle TEXT NOT NULL,
            conditional TEXT NOT NULL,
            except_text TEXT NOT NULL,
            source TEXT NOT NULL,
            source_ref TEXT NOT NULL,
            confidence REAL NOT NULL CHECK(confidence BETWEEN 0 AND 1),
            review_status TEXT NOT NULL,
            raw_tags_json TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE turn_restrictions_rtree USING rtree(
            restriction_id, min_lat, max_lat, min_lon, max_lon
        );

        CREATE TABLE road_rules (
            id INTEGER PRIMARY KEY,
            way_id INTEGER NOT NULL UNIQUE,
            rules_json TEXT NOT NULL,
            road_name TEXT NOT NULL,
            highway TEXT NOT NULL,
            geometry_json TEXT NOT NULL,
            source TEXT NOT NULL,
            source_ref TEXT NOT NULL,
            confidence REAL NOT NULL CHECK(confidence BETWEEN 0 AND 1),
            review_status TEXT NOT NULL,
            raw_tags_json TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE road_rules_rtree USING rtree(
            rule_id, min_lat, max_lat, min_lon, max_lon
        );

        CREATE TABLE data_issues (
            id INTEGER PRIMARY KEY,
            dataset TEXT NOT NULL,
            source_id INTEGER,
            reason TEXT NOT NULL,
            details_json TEXT NOT NULL,
            review_status TEXT NOT NULL DEFAULT 'pending'
        );
        CREATE INDEX idx_alert_type ON alerts(type);
        CREATE INDEX idx_map_data_type ON map_data_points(type_code);
        CREATE INDEX idx_map_data_speed ON map_data_points(speed_kmh);
        CREATE INDEX idx_map_data_link_direction_1_speed ON map_data_road_links(direction_1_speed_kmh);
        CREATE INDEX idx_map_data_link_direction_2_speed ON map_data_road_links(direction_2_speed_kmh);
        CREATE INDEX idx_road_speed ON road_segments(speed_kmh);
        CREATE INDEX idx_turn_restriction_type ON turn_restrictions(restriction);
        CREATE INDEX idx_road_rule_way ON road_rules(way_id);
        """
    )


def build_database(output: Path) -> dict:
    map_data_path = MAP_DATA_DIR / "csv" / "traffic_points.csv"
    map_data_road_links_path = MAP_DATA_DIR / "csv" / "road_links.csv"
    map_data_cities_path = MAP_DATA_DIR / "csv" / "cities.csv"
    map_data_names_path = MAP_DATA_DIR / "csv" / "districts.csv"
    map_data_road_name_quarantine_path = (
        MAP_DATA_DIR / "csv" / "road_name_quarantine.csv"
    )
    extraction_summary_path = MAP_DATA_DIR / "json" / "summary.json"
    source_archive_path = ROOT / "map-data" / "secrect.bin"
    camera_path = SOURCE_DIR / "camera_alerts.geojson"
    road_path = SOURCE_DIR / "road_lines.geojson"
    speed_path = SOURCE_DIR / "speed_signs.geojson"
    osm_sign_path = SOURCE_DIR / "osm_traffic_signs.geojson"
    turn_restriction_path = SOURCE_DIR / "osm_turn_restrictions.geojson"
    road_rule_path = SOURCE_DIR / "osm_road_rules.geojson"
    sign_quarantine_path = SOURCE_DIR / "osm_sign_quarantine.json"
    restriction_quarantine_path = SOURCE_DIR / "osm_restriction_quarantine.json"
    source_paths = tuple(path for path in (
        map_data_path,
        map_data_road_links_path,
        map_data_cities_path,
        map_data_names_path,
        map_data_road_name_quarantine_path,
        extraction_summary_path,
        source_archive_path,
        camera_path,
        road_path,
        speed_path,
        osm_sign_path,
        turn_restriction_path,
        road_rule_path,
        sign_quarantine_path,
        restriction_quarantine_path,
    ) if path.exists())

    map_data_points, map_data_issues = load_map_data_points(map_data_path)
    map_data_cities = load_exact_lookup(map_data_cities_path, ("id", "label"))
    map_data_names = load_exact_lookup(map_data_names_path, ("id", "city_id", "label"))
    extraction_summary = json.loads(extraction_summary_path.read_text(encoding="utf-8"))
    if extraction_summary.get("source_sha256") != sha256(source_archive_path):
        raise ValueError("Extraction summary does not match map-data/secrect.bin")
    map_data_road_name_quarantine_count = 0
    if map_data_road_name_quarantine_path.exists():
        with map_data_road_name_quarantine_path.open(
            encoding="utf-8-sig", newline=""
        ) as quarantine_handle:
            map_data_road_name_quarantine_count = max(
                sum(1 for _ in quarantine_handle) - 1,
                0,
            )
    camera_sources, camera_issues = load_cameras(camera_path)
    camera_clusters = cluster_cameras(camera_sources, CAMERA_MERGE_METERS)
    road_results = validate_roads(road_path)
    speed_observations = load_speed_observations(speed_path)
    osm_signs, osm_sign_issues = load_osm_traffic_signs(osm_sign_path)
    turn_restrictions, turn_restriction_issues = load_osm_turn_restrictions(
        turn_restriction_path
    )
    road_rules, road_rule_issues = load_osm_road_rules(road_rule_path)
    sign_quarantine = load_quarantine(sign_quarantine_path, "osm_traffic_sign")
    restriction_quarantine = load_quarantine(
        restriction_quarantine_path,
        "osm_turn_restriction",
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    connection = sqlite3.connect(output)
    try:
        create_schema(connection)
        generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
        metadata = {
            "contract_id": DATABASE_CONTRACT_ID,
            "contract_version": str(DATABASE_CONTRACT_VERSION),
            "schema_version": str(DATABASE_SCHEMA_VERSION),
            "dataset_version": generated_at,
            "generated_at_utc": generated_at,
            "camera_merge_meters": str(CAMERA_MERGE_METERS),
            "max_road_edge_meters": str(MAX_ROAD_EDGE_METERS),
            "max_road_length_meters": str(MAX_ROAD_LENGTH_METERS),
            "toll_policy": "quarantined_source_flag_unreliable",
            "speed_observation_policy": "reference_only",
            "active_business_layer": "map-data/roadsenz.bin + map-data/edogen.bin",
            "map_data_format": "IGO_X_Y_TYPE_SPEED_DIRTYPE_DIRECTION",
            "map_data_road_graph_format": "ROAD_SN_PROVIDER_ID_INLINE_NAME_DIR1_NAME_ID_DIR2_NAME_ID_DIR1_SPEED_DIR2_SPEED_GEOMETRY",
            "source_archive_sha256": extraction_summary["source_sha256"],
            "source_date": extraction_summary["source_date"],
            "decoder_firmware_sha256": extraction_summary["decoder"]["firmware_sha256"],
            "decoder_table_sha256": extraction_summary["decoder"]["table_sha256"],
            "decoder_operation": extraction_summary["decoder"]["operation"],
        }
        for path in source_paths:
            metadata[f"sha256:{path.name}"] = sha256(path)
        connection.executemany("INSERT INTO metadata(key, value) VALUES(?, ?)", metadata.items())
        connection.executemany(
            "INSERT INTO map_data_city_lookup(id, label) VALUES(?, ?)",
            map_data_cities,
        )
        connection.executemany(
            "INSERT INTO map_data_name_lookup(id, city_id, label) VALUES(?, ?, ?)",
            map_data_names,
        )

        for point_id, point in enumerate(map_data_points, start=1):
            connection.execute(
                """
                INSERT INTO map_data_points(
                    id, source_node_id, type_code, kind, latitude, longitude,
                    speed_kmh, direction_type, direction_degrees, raw_direction,
                    warning_text, source_ref, confidence
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    point_id,
                    point.source_node_id,
                    point.type_code,
                    point.kind,
                    point.latitude,
                    point.longitude,
                    point.speed_kmh,
                    point.direction_type,
                    point.direction_degrees,
                    point.raw_direction,
                    point.warning_text,
                    f"map-data/edogen.bin#{point.source_node_id}",
                    1.0,
                ),
            )
            connection.execute(
                "INSERT INTO map_data_points_rtree VALUES(?, ?, ?, ?, ?)",
                (
                    point_id,
                    point.latitude,
                    point.latitude,
                    point.longitude,
                    point.longitude,
                ),
            )

        map_data_road_link_count = 0
        map_data_road_link_display_speed_count = 0
        map_data_road_link_raw_nonzero_count = 0
        map_data_road_link_issues: list[dict] = []
        link_rows: list[tuple] = []
        link_rtree_rows: list[tuple] = []

        def flush_map_data_road_links() -> None:
            if not link_rows:
                return
            connection.executemany(
                """
                INSERT INTO map_data_road_links(
                    id, road_serial_number, provider_road_id, inline_road_name,
                    direction_1_name_id, direction_2_name_id,
                    direction_1_speed_kmh, direction_2_speed_kmh,
                    geometry_json, confidence
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                link_rows,
            )
            connection.executemany(
                "INSERT INTO map_data_road_links_rtree VALUES(?, ?, ?, ?, ?)",
                link_rtree_rows,
            )
            link_rows.clear()
            link_rtree_rows.clear()

        for link, issue in iter_map_data_road_links(map_data_road_links_path):
            if issue is not None:
                map_data_road_link_issues.append(issue)
                continue
            assert link is not None
            map_data_road_link_count += 1
            if link.direction_1_speed_kmh > 0 or link.direction_2_speed_kmh > 0:
                map_data_road_link_raw_nonzero_count += 1
            if (
                link.direction_1_speed_kmh in VALID_SPEEDS
                and link.direction_1_speed_kmh > 0
            ) or (
                link.direction_2_speed_kmh in VALID_SPEEDS
                and link.direction_2_speed_kmh > 0
            ):
                map_data_road_link_display_speed_count += 1
            lons = [coordinate[0] for coordinate in link.coordinates]
            lats = [coordinate[1] for coordinate in link.coordinates]
            link_rows.append((
                map_data_road_link_count,
                link.road_serial_number,
                link.provider_road_id,
                link.inline_road_name,
                link.direction_1_name_id,
                link.direction_2_name_id,
                link.direction_1_speed_kmh,
                link.direction_2_speed_kmh,
                json.dumps(link.coordinates, ensure_ascii=False, separators=(",", ":")),
                1.0,
            ))
            link_rtree_rows.append((
                map_data_road_link_count,
                min(lats),
                max(lats),
                min(lons),
                max(lons),
            ))
            if len(link_rows) >= 5_000:
                flush_map_data_road_links()
        flush_map_data_road_links()

        for alert_id, cluster in enumerate(camera_clusters, start=1):
            connection.execute(
                """
                INSERT INTO alerts(
                    id, type, latitude, longitude, warning_text, speed_kmh,
                    sign_code, asset_name, source, source_ref, confidence,
                    cluster_size, source_ids_json, raw_attributes_json,
                    direction_scope, direction_degrees, conditional,
                    source_updated_at, review_status
                ) VALUES(?, 'camera', ?, ?, 'Camera cảnh báo', 0, NULL, NULL,
                    'recovered_camera_geojson', NULL, ?, ?, ?, ?,
                    'unknown', NULL, '', ?, 'normalized')
                """,
                (
                    alert_id,
                    cluster.latitude,
                    cluster.longitude,
                    0.75 if len(cluster.source_ids) == 1 else 0.85,
                    len(cluster.source_ids),
                    json.dumps(cluster.source_ids, separators=(",", ":")),
                    json.dumps(cluster.raw_attributes, ensure_ascii=False, separators=(",", ":")),
                    generated_at,
                ),
            )
            connection.execute(
                "INSERT INTO alerts_rtree VALUES(?, ?, ?, ?, ?)",
                (alert_id, cluster.latitude, cluster.latitude, cluster.longitude, cluster.longitude),
            )

        next_alert_id = len(camera_clusters) + 1
        for offset, sign in enumerate(osm_signs):
            alert_id = next_alert_id + offset
            connection.execute(
                """
                INSERT INTO alerts(
                    id, type, latitude, longitude, warning_text, speed_kmh,
                    sign_code, asset_name, source, source_ref, confidence,
                    cluster_size, source_ids_json, raw_attributes_json,
                    direction_scope, direction_degrees, conditional,
                    source_updated_at, review_status
                ) VALUES(?, 'road_sign', ?, ?, ?, ?, ?, ?, 'OpenStreetMap', ?,
                    ?, 1, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    alert_id,
                    sign["latitude"],
                    sign["longitude"],
                    sign["warning_text"],
                    sign["speed_kmh"],
                    sign["sign_code"],
                    sign["asset_name"],
                    sign["source_ref"],
                    sign["confidence"],
                    json.dumps(
                        [f'{sign["source_type"]}/{sign["source_id"]}'],
                        separators=(",", ":"),
                    ),
                    json.dumps(
                        sign["raw_tags"],
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ),
                    sign["direction_scope"],
                    sign["direction_degrees"],
                    sign["conditional"],
                    generated_at,
                    sign["review_status"],
                ),
            )
            connection.execute(
                "INSERT INTO alerts_rtree VALUES(?, ?, ?, ?, ?)",
                (
                    alert_id,
                    sign["latitude"],
                    sign["latitude"],
                    sign["longitude"],
                    sign["longitude"],
                ),
            )

        for restriction_id, restriction in enumerate(turn_restrictions, start=1):
            connection.execute(
                """
                INSERT INTO turn_restrictions(
                    id, source_id, restriction, warning_text, latitude, longitude,
                    from_way_id, to_way_id, via_node_id, vehicle, conditional,
                    except_text, source, source_ref, confidence, review_status,
                    raw_tags_json
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'OpenStreetMap', ?, ?, ?, ?)
                """,
                (
                    restriction_id,
                    restriction["source_id"],
                    restriction["restriction"],
                    restriction["warning_text"],
                    restriction["latitude"],
                    restriction["longitude"],
                    restriction["from_way_id"],
                    restriction["to_way_id"],
                    restriction["via_node_id"],
                    restriction["vehicle"],
                    restriction["conditional"],
                    restriction["except"],
                    restriction["source_ref"],
                    restriction["confidence"],
                    restriction["review_status"],
                    json.dumps(restriction["raw_tags"], ensure_ascii=False, separators=(",", ":")),
                ),
            )
            connection.execute(
                "INSERT INTO turn_restrictions_rtree VALUES(?, ?, ?, ?, ?)",
                (
                    restriction_id,
                    restriction["latitude"],
                    restriction["latitude"],
                    restriction["longitude"],
                    restriction["longitude"],
                ),
            )

        for rule_id, rule in enumerate(road_rules, start=1):
            lons = [point[0] for point in rule["coordinates"]]
            lats = [point[1] for point in rule["coordinates"]]
            connection.execute(
                """
                INSERT INTO road_rules(
                    id, way_id, rules_json, road_name,
                    highway, geometry_json, source, source_ref, confidence,
                    review_status, raw_tags_json
                ) VALUES(?, ?, ?, ?, ?, ?, 'OpenStreetMap', ?, ?, ?, ?)
                """,
                (
                    rule_id,
                    rule["way_id"],
                    json.dumps(rule["rules"], ensure_ascii=False, separators=(",", ":")),
                    rule["road_name"],
                    rule["highway"],
                    json.dumps(rule["coordinates"], separators=(",", ":")),
                    rule["source_ref"],
                    rule["confidence"],
                    rule["review_status"],
                    json.dumps(rule["raw_tags"], ensure_ascii=False, separators=(",", ":")),
                ),
            )
            connection.execute(
                "INSERT INTO road_rules_rtree VALUES(?, ?, ?, ?, ?)",
                (rule_id, min(lats), max(lats), min(lons), max(lons)),
            )
        accepted_roads = [road for road in road_results if road.accepted]
        for road_id, road in enumerate(accepted_roads, start=1):
            lons = [point[0] for point in road.coordinates]
            lats = [point[1] for point in road.coordinates]
            connection.execute(
                """
                INSERT INTO road_segments(
                    id, source_segment_id, road_id, speed_kmh, length_meters,
                    source_province, geometry_json, quality
                ) VALUES(?, ?, ?, ?, ?, ?, ?, 'geometry_validated')
                """,
                (
                    road_id,
                    road.source_segment_id,
                    road.road_id,
                    road.speed_kmh,
                    road.length_meters,
                    road.source_province,
                    json.dumps(road.coordinates, separators=(",", ":")),
                ),
            )
            connection.execute(
                "INSERT INTO road_segments_rtree VALUES(?, ?, ?, ?, ?)",
                (road_id, min(lats), max(lats), min(lons), max(lons)),
            )

        for observation in speed_observations:
            connection.execute(
                """
                INSERT INTO speed_observations(
                    source_id, road_id, speed_kmh, latitude, longitude,
                    source_province, usage
                ) VALUES(?, ?, ?, ?, ?, ?, 'reference_only')
                """,
                (
                    observation["source_id"],
                    observation["road_id"],
                    observation["speed_kmh"],
                    observation["latitude"],
                    observation["longitude"],
                    observation["source_province"],
                ),
            )

        issue_rows = (
            list(map_data_issues)
            + list(map_data_road_link_issues)
            + list(camera_issues)
            + list(osm_sign_issues)
            + list(turn_restriction_issues)
            + list(road_rule_issues)
            + sign_quarantine
            + restriction_quarantine
        )
        issue_rows.extend({
            "dataset": "road",
            "source_id": road.source_segment_id,
            "reason": road.reason,
            "max_edge_meters": round(road.max_edge_meters, 2),
            "length_meters": round(road.length_meters, 2),
        } for road in road_results if not road.accepted)
        issue_rows.append({
            "dataset": "toll",
            "source_id": None,
            "reason": "entire_layer_quarantined",
            "record_count": len(road_results),
            "details": "Every source road was marked as toll; the flag is not credible.",
        })
        for issue in issue_rows:
            connection.execute(
                "INSERT INTO data_issues(dataset, source_id, reason, details_json) VALUES(?, ?, ?, ?)",
                (
                    issue["dataset"],
                    issue.get("source_id"),
                    issue["reason"],
                    json.dumps(issue, ensure_ascii=False, separators=(",", ":")),
                ),
            )
        connection.commit()
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    finally:
        connection.close()

    duplicate_sources = len(camera_sources) - len(camera_clusters)
    road_reason_counts: dict[str, int] = {}
    for road in road_results:
        road_reason_counts[road.reason] = road_reason_counts.get(road.reason, 0) + 1
    report = {
        "contract_id": DATABASE_CONTRACT_ID,
        "contract_version": DATABASE_CONTRACT_VERSION,
        "schema_version": DATABASE_SCHEMA_VERSION,
        "generated_at_utc": generated_at,
        "integrity_check": integrity,
        "rules": {
            "camera_merge_meters": CAMERA_MERGE_METERS,
            "vietnam_mainland_bounds": VIETNAM_MAINLAND_BOUNDS,
            "max_road_edge_meters": MAX_ROAD_EDGE_METERS,
            "max_road_length_meters": MAX_ROAD_LENGTH_METERS,
        },
        "map_data": {
            "source_count": len(map_data_points) + len(map_data_issues),
            "production_count": len(map_data_points),
            "quarantined_count": len(map_data_issues),
            "type_counts": {
                str(type_code): sum(
                    point.type_code == type_code for point in map_data_points
                )
                for type_code in sorted({point.type_code for point in map_data_points})
            },
            "speed_point_count": sum(point.speed_kmh > 0 for point in map_data_points),
            "uninterpreted_direction_count": sum(
                point.raw_direction > 359 for point in map_data_points
            ),
        },
        "map_data_road_links": {
            "source_count": map_data_road_link_count + len(map_data_road_link_issues),
            "production_count": map_data_road_link_count,
            "quarantined_count": len(map_data_road_link_issues),
            "raw_nonzero_directional_value_count": map_data_road_link_raw_nonzero_count,
            "display_supported_directional_speed_count": map_data_road_link_display_speed_count,
            "raw_directional_values_preserved": True,
            "unverified_road_names_quarantined": map_data_road_name_quarantine_count,
        },
        "camera": {
            "source_count": len(camera_sources) + len(camera_issues),
            "outside_bounds": len(camera_issues),
            "accepted_source_points": len(camera_sources),
            "production_clusters": len(camera_clusters),
            "merged_duplicate_points": duplicate_sources,
        },
        "roads": {
            "source_count": len(road_results),
            "accepted_count": sum(road.accepted for road in road_results),
            "quarantined_count": sum(not road.accepted for road in road_results),
            "reason_counts": road_reason_counts,
            "accepted_with_known_speed": sum(
                road.accepted and road.speed_kmh > 0 for road in road_results
            ),
        },
        "speed_observations": {
            "reference_only_count": len(speed_observations),
        },
        "osm_traffic_signs": {
            "production_count": len(osm_signs),
            "quarantined_count": len(osm_sign_issues) + len(sign_quarantine),
        },
        "osm_turn_restrictions": {
            "production_count": len(turn_restrictions),
            "quarantined_count": (
                len(turn_restriction_issues) + len(restriction_quarantine)
            ),
        },
        "osm_road_rules": {
            "production_count": len(road_rules),
            "quarantined_count": len(road_rule_issues),
        },
        "toll": {
            "source_count": len(road_results),
            "production_count": 0,
            "policy": "quarantined",
        },
        "sources": {
            path.name: {"sha256": sha256(path), "bytes": path.stat().st_size}
            for path in source_paths
        },
        "output": str(output),
    }
    report["database"] = {
        "path": str(output),
        "bytes": output.stat().st_size,
        "sha256": sha256(output),
    }
    return report


def write_report(report: dict) -> None:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    json_path = REPORT_DIR / "data_quality.json"
    markdown_path = REPORT_DIR / "data_quality.md"
    json_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    camera = report["camera"]
    map_data = report["map_data"]
    map_data_roads = report["map_data_road_links"]
    roads = report["roads"]
    signs = report["osm_traffic_signs"]
    restrictions = report["osm_turn_restrictions"]
    road_rules = report["osm_road_rules"]
    markdown = f"""# VietDrive data quality report

Generated: {report["generated_at_utc"]}

## Production result

- Database integrity: {report["integrity_check"]}
- map-data points published: {map_data["production_count"]}
- map-data speed-camera points: {map_data["speed_point_count"]}
- map-data raw directions left uninterpreted (>359): {map_data["uninterpreted_direction_count"]}
- map-data directional road links published: {map_data_roads["production_count"]}
- map-data road links with a non-zero raw directional value: {map_data_roads["raw_nonzero_directional_value_count"]}
- map-data road links with a display-supported directional speed: {map_data_roads["display_supported_directional_speed_count"]}
- raw directional values preserved without conversion: {map_data_roads["raw_directional_values_preserved"]}
- unverified road names preserved as raw hex in quarantine: {map_data_roads["unverified_road_names_quarantined"]}
- map-data road links quarantined: {map_data_roads["quarantined_count"]}
- Camera source points: {camera["source_count"]}
- Camera production clusters: {camera["production_clusters"]}
- Camera points merged as near-duplicates: {camera["merged_duplicate_points"]}
- Camera points outside bounds: {camera["outside_bounds"]}
- Road source segments: {roads["source_count"]}
- Road segments accepted: {roads["accepted_count"]}
- Accepted roads with known speed: {roads["accepted_with_known_speed"]}
- Road segments quarantined: {roads["quarantined_count"]}
- Speed observations retained for reference only: {report["speed_observations"]["reference_only_count"]}
- Recognized OSM traffic signs published: {signs["production_count"]}
- OSM traffic signs quarantined: {signs["quarantined_count"]}
- OSM turn restrictions published: {restrictions["production_count"]}
- OSM turn restrictions quarantined: {restrictions["quarantined_count"]}
- OSM road-rule ways published: {road_rules["production_count"]}
- Toll records published: 0

## Policy

Every decoded directional byte from map-data/roadsenz.bin is retained exactly.
The active app only displays literal speed values in the explicit supported
set; it does not convert or infer other values. map-data/edogen.bin supplies upcoming iGO points using
X,Y,TYPE,SPEED,DIRTYPE,DIRECTION. The retained legacy/OSM layers remain audit
data and do not override the provider road graph. Invalid graph coordinates are
quarantined. The toll layer is quarantined because every legacy road was
flagged as a toll road.
"""
    markdown_path.write_text(markdown, encoding="utf-8")
    manifest = {
        "schemaVersion": 1,
        "databaseContract": report["contract_id"],
        "databaseContractVersion": report["contract_version"],
        "databaseSchemaVersion": report["schema_version"],
        "datasetVersion": report["generated_at_utc"],
        "minimumAppVersion": "0.3.0",
        "database": {
            "fileName": "map_database_v2.sqlite",
            "bytes": report["database"]["bytes"],
            "sha256": report["database"]["sha256"],
        },
        "counts": {
            "alerts": report["map_data"]["production_count"],
            "mapDataPoints": report["map_data"]["production_count"],
            "speedPoints": report["map_data"]["speed_point_count"],
            "mapDataRoadLinks": report["map_data_road_links"]["production_count"],
            "directionalSpeedLinks": report["map_data_road_links"]["display_supported_directional_speed_count"],
            "turnRestrictions": report["osm_turn_restrictions"]["production_count"],
            "roadRuleWays": report["osm_road_rules"]["production_count"],
        },
        "sources": report["sources"],
    }
    (SOURCE_DIR / "data_manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    report = build_database(args.output.resolve())
    write_report(report)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

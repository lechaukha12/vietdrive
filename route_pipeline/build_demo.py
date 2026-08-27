#!/usr/bin/env python3
"""Build the real-road TP.HCM to Phan Thiet demo and OSM sign overlay."""

from __future__ import annotations

import hashlib
import json
import math
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROUTE = (
    ROOT
    / "VietDriveIOS"
    / "VietDrive"
    / "Resources"
    / "Demo"
    / "hcm_phan_thiet_route.json"
)
OUTPUT_SIGNS = ROOT / "extracted" / "osm_traffic_signs.geojson"
OUTPUT_REPORT = Path(__file__).resolve().parent / "route_report.json"
CACHE_DIR = Path(__file__).resolve().parent / "cache"

OSRM_ENDPOINT = "https://router.project-osrm.org"
OVERPASS_ENDPOINT = "https://overpass-api.de/api/interpreter"
OVERPASS_SECONDARY = "https://overpass.kumi.systems/api/interpreter"
OSM_ATTRIBUTION = "© OpenStreetMap contributors"
OSM_LICENSE = "ODbL 1.0"

START = (106.6851, 10.7755)
END = (108.1075, 10.9289)
SUPPORTED_SPEEDS = {30, 40, 50, 60, 70, 80, 90, 100, 110, 120}


@dataclass(frozen=True)
class WaySegment:
    a: tuple[float, float]
    b: tuple[float, float]
    speed_limit: int | None
    highway: str
    name: str
    osm_id: int


def curl_json(arguments: list[str], max_time: int = 180) -> dict:
    command = [
        "curl",
        "--http1.1",
        "--connect-timeout",
        "15",
        "--max-time",
        str(max_time),
        "--retry",
        "2",
        "--retry-all-errors",
        "-fsSL",
        "-A",
        "VietDriveRoutePipeline/0.1",
    ] + arguments
    return json.loads(subprocess.run(command, check=True, capture_output=True).stdout)


def haversine_meters(a: tuple[float, float], b: tuple[float, float]) -> float:
    lon1, lat1 = a
    lon2, lat2 = b
    radius = 6_371_008.8
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)
    value = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )
    return 2 * radius * math.asin(min(1.0, math.sqrt(value)))


def point_segment_distance(
    point: tuple[float, float],
    a: tuple[float, float],
    b: tuple[float, float],
) -> float:
    lon, lat = point
    scale_y = 111_320.0
    scale_x = scale_y * math.cos(math.radians(lat))
    ax, ay = (a[0] - lon) * scale_x, (a[1] - lat) * scale_y
    bx, by = (b[0] - lon) * scale_x, (b[1] - lat) * scale_y
    dx, dy = bx - ax, by - ay
    denominator = dx * dx + dy * dy
    if denominator == 0:
        return math.hypot(ax, ay)
    projection = max(0.0, min(1.0, -(ax * dx + ay * dy) / denominator))
    return math.hypot(ax + projection * dx, ay + projection * dy)


def perpendicular_distance(
    point: tuple[float, float],
    start: tuple[float, float],
    end: tuple[float, float],
) -> float:
    return point_segment_distance(point, start, end)


def simplify(points: list[tuple[float, float]], tolerance_meters: float) -> list[tuple[float, float]]:
    if len(points) <= 2:
        return points
    distances = [
        perpendicular_distance(point, points[0], points[-1])
        for point in points[1:-1]
    ]
    if not distances:
        return [points[0], points[-1]]
    maximum = max(distances)
    index = distances.index(maximum) + 1
    if maximum <= tolerance_meters:
        return [points[0], points[-1]]
    return (
        simplify(points[: index + 1], tolerance_meters)[:-1]
        + simplify(points[index:], tolerance_meters)
    )


def fetch_shortest_route() -> tuple[dict, dict]:
    url = (
        f"{OSRM_ENDPOINT}/route/v1/driving/"
        f"{START[0]},{START[1]};{END[0]},{END[1]}"
        "?overview=full&geometries=geojson&steps=true&annotations=true&alternatives=3"
    )
    response = curl_json([url], max_time=90)
    if response.get("code") != "Ok" or not response.get("routes"):
        raise RuntimeError(f"OSRM route failed: {response.get('code')}")
    return min(response["routes"], key=lambda item: item["distance"]), response


def route_polyline_argument(coordinates: list[tuple[float, float]]) -> str:
    reduced = simplify(coordinates, 60.0)
    return ",".join(f"{lat:.6f},{lon:.6f}" for lon, lat in reduced)


def fetch_corridor_data(polyline: str) -> dict:
    query = f"""
        [out:json][timeout:120];
        (
          way(around:80,{polyline})[highway][maxspeed];
          nwr(around:120,{polyline})[traffic_sign];
          node(around:120,{polyline})[highway~"^(stop|give_way)$"];
        );
        out tags geom;
    """
    return curl_json(
        [
            "--data-urlencode",
            "data=" + query,
            OVERPASS_ENDPOINT,
        ]
    )


def fetch_city_signs() -> dict:
    query = """
        [out:json][timeout:120];
        (
          nwr(10.60,106.45,10.95,106.95)[traffic_sign];
          nwr(10.80,107.95,11.10,108.35)[traffic_sign];
          node(10.60,106.45,10.95,106.95)[highway~"^(stop|give_way)$"];
          node(10.80,107.95,11.10,108.35)[highway~"^(stop|give_way)$"];
        );
        out center tags;
    """
    return curl_json(
        [
            "--data-urlencode",
            "data=" + query,
            OVERPASS_SECONDARY,
        ]
    )


def cached_fetch(name: str, fetcher) -> tuple[dict, str]:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = CACHE_DIR / f"{name}.json"
    try:
        payload = fetcher()
        path.write_text(
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        return payload, "live"
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        if not path.exists():
            raise
        return json.loads(path.read_text(encoding="utf-8")), "cache"


def parse_speed(tags: dict) -> int | None:
    raw_values = [
        tags.get("maxspeed"),
        tags.get("maxspeed:forward"),
        tags.get("maxspeed:backward"),
    ]
    values: list[int] = []
    for raw in raw_values:
        if not raw:
            continue
        for number in re.findall(r"\d+(?:\.\d+)?", str(raw)):
            speed = float(number)
            if "mph" in str(raw).lower():
                speed *= 1.609344
            rounded = int(round(speed / 10) * 10)
            if 10 <= rounded <= 140:
                values.append(rounded)
    return min(values) if values else None


def fallback_speed(highway: str) -> int:
    return {
        "motorway": 100,
        "motorway_link": 60,
        "trunk": 90,
        "trunk_link": 60,
        "primary": 80,
        "primary_link": 60,
        "secondary": 70,
        "secondary_link": 50,
        "tertiary": 60,
        "tertiary_link": 50,
        "residential": 50,
        "unclassified": 50,
        "service": 30,
        "living_street": 20,
    }.get(highway, 50)


def build_way_segments(elements: list[dict]) -> list[WaySegment]:
    result = []
    for element in elements:
        tags = element.get("tags") or {}
        geometry = element.get("geometry") or []
        if element.get("type") != "way" or len(geometry) < 2 or "highway" not in tags:
            continue
        speed = parse_speed(tags)
        for left, right in zip(geometry, geometry[1:]):
            result.append(WaySegment(
                a=(float(left["lon"]), float(left["lat"])),
                b=(float(right["lon"]), float(right["lat"])),
                speed_limit=speed,
                highway=str(tags.get("highway") or ""),
                name=str(tags.get("name") or tags.get("ref") or ""),
                osm_id=int(element["id"]),
            ))
    return result


def grid_key(point: tuple[float, float]) -> tuple[int, int]:
    return int(math.floor(point[0] / 0.01)), int(math.floor(point[1] / 0.01))


def index_segments(segments: list[WaySegment]) -> dict[tuple[int, int], list[WaySegment]]:
    index: dict[tuple[int, int], list[WaySegment]] = {}
    for segment in segments:
        min_key = grid_key((min(segment.a[0], segment.b[0]), min(segment.a[1], segment.b[1])))
        max_key = grid_key((max(segment.a[0], segment.b[0]), max(segment.a[1], segment.b[1])))
        for x in range(min_key[0], max_key[0] + 1):
            for y in range(min_key[1], max_key[1] + 1):
                index.setdefault((x, y), []).append(segment)
    return index


def nearest_segment(
    point: tuple[float, float],
    index: dict[tuple[int, int], list[WaySegment]],
) -> tuple[WaySegment | None, float]:
    key = grid_key(point)
    candidates = []
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            candidates.extend(index.get((key[0] + dx, key[1] + dy), []))
    best_segment = None
    best_distance = float("inf")
    for segment in candidates:
        distance = point_segment_distance(point, segment.a, segment.b)
        if distance < best_distance:
            best_segment, best_distance = segment, distance
    return best_segment, best_distance


def normalized_sign(element: dict) -> dict | None:
    tags = element.get("tags") or {}
    traffic_sign = str(tags.get("traffic_sign") or "")
    highway = str(tags.get("highway") or "")
    code = None
    asset = None
    message = None

    speed = parse_speed(tags)
    if traffic_sign in {"maxspeed", "residential"} and speed in SUPPORTED_SPEEDS:
        code = f"P127.{speed}"
        asset = f"TrafficSigns/TrafficSign_P127_{speed}"
        message = f"Giới hạn tốc độ {speed} km/h"
    elif highway == "stop" or traffic_sign.lower() == "stop":
        code, asset, message = "P122", "TrafficSigns/TrafficSign_P122", "Dừng lại"
    elif highway == "give_way" or traffic_sign.lower() == "give_way":
        code, asset, message = "W208", "TrafficSigns/TrafficSign_W208", "Nhường đường"
    elif "P.130" in traffic_sign:
        code, asset, message = "P130", "TrafficSigns/TrafficSign_P130", "Cấm dừng xe và đỗ xe"
    elif "P.103c" in traffic_sign:
        code, asset, message = "P103c", "TrafficSigns/TrafficSign_P103c", "Cấm ô tô rẽ trái"
    elif traffic_sign in {"VN:102", "VN:P.102"}:
        code, asset, message = "P102", "TrafficSigns/TrafficSign_P102", "Cấm đi ngược chiều"
    elif traffic_sign in {"VN:302a", "VN:R.302a"}:
        code, asset, message = "R302a", "TrafficSigns/TrafficSign_R302a", "Hướng phải phải đi vòng"
    elif "W.245" in traffic_sign:
        code, asset, message = "W245a", "TrafficSigns/TrafficSign_W245a", "Đi chậm"
    elif traffic_sign == "overtaking":
        code, asset, message = "P125", "TrafficSigns/TrafficSign_P125", "Cấm vượt"
    if not code:
        return None

    latitude = element.get("lat") or (element.get("center") or {}).get("lat")
    longitude = element.get("lon") or (element.get("center") or {}).get("lon")
    if latitude is None or longitude is None:
        return None
    osm_type = str(element["type"])
    osm_id = int(element["id"])
    return {
        "type": "Feature",
        "geometry": {
            "type": "Point",
            "coordinates": [float(longitude), float(latitude)],
        },
        "properties": {
            "type": "road_sign",
            "sign_code": code,
            "asset_name": asset,
            "warning_text": message,
            "osm_type": osm_type,
            "osm_id": osm_id,
            "osm_url": f"https://www.openstreetmap.org/{osm_type}/{osm_id}",
            "source": "OpenStreetMap",
            "source_timestamp_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
            "tags": tags,
        },
    }


def cumulative_distances(coordinates: list[tuple[float, float]]) -> list[float]:
    result = [0.0]
    for left, right in zip(coordinates, coordinates[1:]):
        result.append(result[-1] + haversine_meters(left, right))
    return result


def build_route_payload(route: dict, corridor_elements: list[dict]) -> tuple[dict, dict]:
    coordinates = [
        (float(point[0]), float(point[1]))
        for point in route["geometry"]["coordinates"]
    ]
    distances = cumulative_distances(coordinates)
    segments = build_way_segments(corridor_elements)
    segment_index = index_segments(segments)
    explicit_count = 0
    points = []
    current_limit = 50
    current_name = ""
    for coordinate, distance in zip(coordinates, distances):
        segment, match_distance = nearest_segment(coordinate, segment_index)
        if segment is not None and match_distance <= 90:
            if segment.speed_limit:
                current_limit = segment.speed_limit
                source = "osm_maxspeed"
                explicit_count += 1
            else:
                current_limit = fallback_speed(segment.highway)
                source = "road_class_fallback"
            current_name = segment.name or current_name
            osm_way_id = segment.osm_id
        else:
            source = "conservative_fallback"
            current_limit = min(current_limit, 60)
            osm_way_id = None
        points.append({
            "latitude": coordinate[1],
            "longitude": coordinate[0],
            "distance_meters": round(distance, 2),
            "speed_limit_kmh": current_limit,
            "speed_source": source,
            "road_name": current_name,
            "osm_way_id": osm_way_id,
        })

    maneuvers = []
    cumulative = 0.0
    for leg in route.get("legs", []):
        for step in leg.get("steps", []):
            maneuver = step.get("maneuver") or {}
            maneuvers.append({
                "distance_meters": round(cumulative, 2),
                "type": str(maneuver.get("type") or ""),
                "modifier": str(maneuver.get("modifier") or ""),
                "road_name": str(step.get("name") or ""),
                "instruction": maneuver_instruction(
                    str(maneuver.get("type") or ""),
                    str(maneuver.get("modifier") or ""),
                    str(step.get("name") or ""),
                ),
            })
            cumulative += float(step.get("distance") or 0)

    payload = {
        "schema_version": 1,
        "name": "TP.HCM → Phan Thiết",
        "generated_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "routing_engine": "OSRM",
        "routing_profile": "driving",
        "selection": "minimum distance among returned alternatives",
        "distance_meters": round(float(route["distance"]), 1),
        "duration_seconds": round(float(route["duration"]), 1),
        "demo_time_scale": 8.0,
        "start": {"name": "TP. Hồ Chí Minh", "latitude": START[1], "longitude": START[0]},
        "end": {"name": "Phan Thiết", "latitude": END[1], "longitude": END[0]},
        "attribution": OSM_ATTRIBUTION,
        "license": OSM_LICENSE,
        "points": points,
        "maneuvers": maneuvers,
    }
    quality = {
        "route_point_count": len(points),
        "explicit_maxspeed_points": explicit_count,
        "explicit_maxspeed_coverage_percent": round(100 * explicit_count / len(points), 1),
        "way_segment_count": len(segments),
    }
    return payload, quality


def maneuver_instruction(kind: str, modifier: str, road_name: str) -> str:
    road = f" vào {road_name}" if road_name else ""
    if kind == "arrive":
        return "Đã đến Phan Thiết"
    if kind == "depart":
        return f"Khởi hành{road}"
    if kind in {"turn", "end of road"}:
        mapping = {
            "left": "Rẽ trái",
            "slight left": "Chếch trái",
            "sharp left": "Rẽ ngoặt trái",
            "right": "Rẽ phải",
            "slight right": "Chếch phải",
            "sharp right": "Rẽ ngoặt phải",
            "straight": "Đi thẳng",
        }
        return mapping.get(modifier, "Chuyển hướng") + road
    if kind in {"merge", "on ramp", "off ramp", "fork"}:
        return "Đi theo nhánh đường" + road
    if kind == "roundabout":
        return "Đi vào vòng xuyến" + road
    return "Tiếp tục" + road


def main() -> None:
    route, osrm_response = fetch_shortest_route()
    coordinates = [
        (float(point[0]), float(point[1]))
        for point in route["geometry"]["coordinates"]
    ]
    corridor, corridor_source = cached_fetch(
        "route_corridor",
        lambda: fetch_corridor_data(route_polyline_argument(coordinates)),
    )
    existing_features = []
    if OUTPUT_SIGNS.exists():
        existing_features = json.loads(
            OUTPUT_SIGNS.read_text(encoding="utf-8")
        ).get("features", [])
    try:
        city_signs, city_source = cached_fetch("city_signs", fetch_city_signs)
    except subprocess.CalledProcessError:
        city_signs, city_source = {"elements": []}, "previous_snapshot"
    route_payload, quality = build_route_payload(route, corridor["elements"])

    unique_elements = {}
    for element in corridor["elements"] + city_signs["elements"]:
        unique_elements[(element["type"], element["id"])] = element
    features = [
        feature
        for element in unique_elements.values()
        if (feature := normalized_sign(element)) is not None
    ]
    feature_index = {
        (
            feature["properties"].get("osm_type"),
            feature["properties"].get("osm_id"),
        ): feature
        for feature in existing_features
    }
    feature_index.update({
        (
            feature["properties"].get("osm_type"),
            feature["properties"].get("osm_id"),
        ): feature
        for feature in features
    })
    features = list(feature_index.values())
    features.sort(key=lambda item: (
        item["properties"]["sign_code"],
        item["properties"]["osm_type"],
        item["properties"]["osm_id"],
    ))
    signs_payload = {
        "type": "FeatureCollection",
        "name": "VietDrive OSM traffic signs",
        "attribution": OSM_ATTRIBUTION,
        "license": OSM_LICENSE,
        "features": features,
    }

    OUTPUT_ROUTE.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_SIGNS.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_ROUTE.write_text(
        json.dumps(route_payload, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    OUTPUT_SIGNS.write_text(
        json.dumps(signs_payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    report = {
        "generated_at_utc": route_payload["generated_at_utc"],
        "route": {
            "distance_meters": route_payload["distance_meters"],
            "duration_seconds": route_payload["duration_seconds"],
            "alternative_count": len(osrm_response["routes"]),
            **quality,
        },
        "traffic_signs": {
            "published_count": len(features),
            "corridor_snapshot": corridor_source,
            "city_snapshot": city_source,
            "by_code": {
                code: sum(
                    feature["properties"]["sign_code"] == code
                    for feature in features
                )
                for code in sorted({
                    feature["properties"]["sign_code"] for feature in features
                })
            },
        },
        "outputs": {
            "route": str(OUTPUT_ROUTE),
            "route_sha256": hashlib.sha256(OUTPUT_ROUTE.read_bytes()).hexdigest(),
            "signs": str(OUTPUT_SIGNS),
            "signs_sha256": hashlib.sha256(OUTPUT_SIGNS.read_bytes()).hexdigest(),
        },
    }
    OUTPUT_REPORT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Extract physical traffic-sign nodes from a Vietnam OSM PBF snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import osmium

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INPUT = Path(__file__).resolve().parent / "cache" / "vietnam-latest.osm.pbf"
DEFAULT_OUTPUT = ROOT / "extracted" / "osm_traffic_signs.geojson"
REPORT_PATH = Path(__file__).resolve().parent / "sign_report.json"
QUARANTINE_PATH = ROOT / "extracted" / "osm_sign_quarantine.json"

ASSETS = {
    "P101": ("TrafficSigns/TrafficSign_P101", "Đường cấm"),
    "P102": ("TrafficSigns/TrafficSign_P102", "Cấm đi ngược chiều"),
    "P103c": ("TrafficSigns/TrafficSign_P103c", "Cấm ô tô rẽ trái"),
    "P122": ("TrafficSigns/TrafficSign_P122", "Dừng lại"),
    "P123a": ("TrafficSigns/TrafficSign_P123a", "Cấm rẽ trái"),
    "P123b": ("TrafficSigns/TrafficSign_P123b", "Cấm rẽ phải"),
    "P124a": ("TrafficSigns/TrafficSign_P124a", "Cấm quay đầu xe bên trái"),
    "P124b": ("TrafficSigns/TrafficSign_P124b", "Cấm quay đầu xe bên phải"),
    "P125": ("TrafficSigns/TrafficSign_P125", "Cấm vượt"),
    "DP133": ("TrafficSigns/TrafficSign_DP133", "Hết cấm vượt"),
    "P130": ("TrafficSigns/TrafficSign_P130", "Cấm dừng xe và đỗ xe"),
    "P131a": ("TrafficSigns/TrafficSign_P131a", "Cấm đỗ xe"),
    "P131b": ("TrafficSigns/TrafficSign_P131b", "Cấm đỗ xe ngày lẻ"),
    "P131c": ("TrafficSigns/TrafficSign_P131c", "Cấm đỗ xe ngày chẵn"),
    "R301a": ("TrafficSigns/TrafficSign_R301a", "Chỉ được đi thẳng"),
    "R301b": ("TrafficSigns/TrafficSign_R301b", "Chỉ được rẽ phải"),
    "R301c": ("TrafficSigns/TrafficSign_R301c", "Chỉ được rẽ trái"),
    "R420": ("TrafficSigns/TrafficSign_R420", "Bắt đầu khu đông dân cư"),
    "R421": ("TrafficSigns/TrafficSign_R421", "Hết khu đông dân cư"),
    "W208": ("TrafficSigns/TrafficSign_W208", "Nhường đường"),
    "W210": ("TrafficSigns/TrafficSign_Railway", "Giao nhau với đường sắt"),
    "W224": ("TrafficSigns/TrafficSign_W224", "Đường người đi bộ cắt ngang"),
    "W225": ("TrafficSigns/TrafficSign_W225", "Trẻ em"),
    "W240": ("TrafficSigns/TrafficSign_Tunnel", "Đường hầm"),
    "W245a": ("TrafficSigns/TrafficSign_W245a", "Đi chậm"),
    "R302a": ("TrafficSigns/TrafficSign_R302a", "Hướng phải phải đi vòng"),
    "I437": ("TrafficSigns/TrafficSign_I437", "Đường cao tốc"),
}
SUPPORTED_SPEEDS = {30, 40, 50, 60, 70, 80, 90, 100, 110, 120}

GENERIC_CODES = {
    "STOP": "P122",
    "GIVE_WAY": "W208",
    "YIELD": "W208",
    "NO_ENTRY": "P102",
    "NO_LEFT_TURN": "P123a",
    "NO_RIGHT_TURN": "P123b",
    "NO_U_TURN": "P124a",
    "OVERTAKING": "P125",
    "NO_OVERTAKING": "P125",
    "NO_STOPPING": "P130",
    "NO_PARKING": "P131a",
}

# Vietnamese and English free-text patterns commonly found in OSM traffic_sign
# values. Patterns are tried in order; the first match wins.
FREETEXT_PATTERNS: list[tuple[re.Pattern, str]] = [
    # Vietnamese prohibition signs
    (re.compile(r"[Cc]ấm.*ô tô.*rẽ trái", re.IGNORECASE), "P103c"),
    (re.compile(r"[Cc]ấm.*ô tô.*rẽ phải", re.IGNORECASE), "P103c"),  # mirror
    (re.compile(r"[Cc]ấm.*rẽ trái", re.IGNORECASE), "P123a"),
    (re.compile(r"[Cc]ấm.*rẽ phải", re.IGNORECASE), "P123b"),
    (re.compile(r"[Cc]ấm.*quay đầu", re.IGNORECASE), "P124a"),
    (re.compile(r"[Cc]ấm.*ngược chiều", re.IGNORECASE), "P102"),
    (re.compile(r"[Cc]ấm.*đi thẳng", re.IGNORECASE), "P123c"),
    (re.compile(r"[Cc]ấm.*dừng.*đỗ", re.IGNORECASE), "P130"),
    (re.compile(r"[Cc]ấm.*dừng", re.IGNORECASE), "P130"),
    (re.compile(r"[Cc]ấm.*đỗ.*ngày lẻ", re.IGNORECASE), "P131b"),
    (re.compile(r"[Cc]ấm.*đỗ.*ngày chẵn", re.IGNORECASE), "P131c"),
    (re.compile(r"[Cc]ấm.*đỗ", re.IGNORECASE), "P131a"),
    (re.compile(r"[Cc]ấm.*vượt", re.IGNORECASE), "P125"),
    (re.compile(r"[Cc]ấm.*ô tô", re.IGNORECASE), "P103a"),
    (re.compile(r"[Dd]ừng lại", re.IGNORECASE), "P122"),
    (re.compile(r"[Đđ]ường cấm", re.IGNORECASE), "P101"),
    # English descriptions
    (re.compile(r"Go straight.*Turn right", re.IGNORECASE), "R301e"),
    (re.compile(r"Go straight.*Turn left", re.IGNORECASE), "R301d"),
    (re.compile(r"Turn left.*Turn right", re.IGNORECASE), "R301f"),
    (re.compile(r"No left turn", re.IGNORECASE), "P123a"),
    (re.compile(r"No right turn", re.IGNORECASE), "P123b"),
    (re.compile(r"No U[- ]?turn", re.IGNORECASE), "P124a"),
    (re.compile(r"No entry", re.IGNORECASE), "P102"),
    (re.compile(r"No overtaking", re.IGNORECASE), "P125"),
    (re.compile(r"No stopping", re.IGNORECASE), "P130"),
    (re.compile(r"No parking", re.IGNORECASE), "P131a"),
    (re.compile(r"Keep right", re.IGNORECASE), "R302a"),
    (re.compile(r"Slow down", re.IGNORECASE), "W245a"),
]

# A small set of bare numbers that OSM contributors use after the VN country
# prefix. Only unambiguous codes backed by an app asset are accepted.
BARE_VN_CODES = {
    "102": "P102",
    "124A": "P124a",
    "124B": "P124b",
    "301A": "R301a",
    "301B": "R301b",
    "301C": "R301c",
    "302A": "R302a",
    "420": "R420",
    "421": "R421",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_speed(tags: dict[str, str]) -> int | None:
    raw = tags.get("maxspeed") or tags.get("maxspeed:forward") or tags.get("maxspeed:backward")
    if not raw:
        return None
    match = re.search(r"\d{2,3}", raw)
    if not match:
        return None
    speed = int(match.group())
    if "mph" in raw.lower():
        speed = int(round(speed * 1.609344 / 10) * 10)
    return speed if speed in SUPPORTED_SPEEDS else None


def direct_code(token: str) -> str | None:
    normalized = token.strip().upper().replace(" ", "")
    if not normalized or normalized in {"YES", "TRAFFIC_SIGN", "CITY_LIMIT"}:
        return None
    if normalized.startswith("VN:"):
        normalized = normalized[3:]
    elif re.match(r"^[A-Z]{2}:", normalized):
        return None
    normalized = normalized.replace("-", ".")
    if normalized in BARE_VN_CODES:
        return BARE_VN_CODES[normalized]

    speed_match = re.search(r"(?:P\.)?127(?:[.:[(]?)(\d{2,3})", normalized)
    if speed_match:
        speed = int(speed_match.group(1))
        return f"P127.{speed}" if speed in SUPPORTED_SPEEDS else None

    match = re.search(r"(?:^|\b)([PWRIS])\.?([0-9]{2,3})([A-Z]?)(?:\b|:)", normalized)
    if not match:
        generic = GENERIC_CODES.get(normalized)
        if generic:
            return generic
        # Try Vietnamese/English free-text patterns as a last resort.
        original_lower = token.strip()
        for pattern, code in FREETEXT_PATTERNS:
            if pattern.search(original_lower):
                return code
        return None
    prefix, number, suffix = match.groups()
    candidate = f"{prefix}{int(number)}{suffix.lower()}"
    return candidate if candidate in ASSETS else None


def recognized_codes(tags: dict[str, str]) -> list[str]:
    codes: list[str] = []
    highway = tags.get("highway", "").lower()
    if highway == "stop":
        codes.append("P122")
    elif highway == "give_way":
        codes.append("W208")

    sign_values = [
        tags.get("traffic_sign", ""),
        tags.get("traffic_sign:forward", ""),
        tags.get("traffic_sign:backward", ""),
    ]
    for raw in sign_values:
        for token in re.split(r"[;,]", raw):
            code = direct_code(token)
            if code:
                codes.append(code)

    joined = ";".join(sign_values).lower()
    speed = parse_speed(tags)
    if speed and ("maxspeed" in joined or "p.127" in joined or "p127" in joined):
        codes.append(f"P127.{speed}")

    return list(dict.fromkeys(codes))


def direction_scope(tags: dict[str, str]) -> str:
    """Return how a physical sign applies relative to the mapped OSM way."""
    has_forward = bool(tags.get("traffic_sign:forward"))
    has_backward = bool(tags.get("traffic_sign:backward"))
    if has_forward and has_backward:
        return "both"
    if has_forward:
        return "forward"
    if has_backward:
        return "backward"
    return "unknown"


def asset_for(code: str) -> tuple[str, str] | None:
    if code.startswith("P127."):
        speed = int(code.split(".", 1)[1])
        return (f"TrafficSigns/TrafficSign_P127_{speed}", f"Giới hạn tốc độ {speed} km/h")
    return ASSETS.get(code)


def extract_conditional(raw_text: str) -> str:
    """Extract a time-range conditional from free-text Vietnamese or OSM syntax.

    Returns an OSM-style time string (e.g. "06:00-22:00") or empty string.
    Handles forms like:
      - "Cấm ô tô rẽ trái từ 6:00AM đến 22:00PM"
      - "no @ (08:00-17:00)"
      - "Mo-Sa 06:00-21:00"
    """
    # Standard OSM conditional: "no @ (Mo-Fr 06:00-22:00)"
    osm_match = re.search(r"@\s*\(([^)]+)\)", raw_text)
    if osm_match:
        return osm_match.group(1).strip()
    # Vietnamese: "từ 6:00AM đến 22:00PM" or "6:00 - 22:00"
    normalized = (
        raw_text
        .replace("đến", "-")
        .replace("tới", "-")
        .replace(" to ", "-")
    )
    normalized = re.sub(r"(?i)\s*[ap]m", "", normalized)
    time_match = re.search(r"(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})", normalized)
    if time_match:
        return f"{time_match.group(1)}-{time_match.group(2)}"
    return ""


class SignHandler(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.raw_nodes: list[dict] = []
        self.raw_value_counts: Counter[str] = Counter()
        self.maxspeed_counts: Counter[str] = Counter()

    def node(self, node) -> None:
        tags = {tag.k: tag.v for tag in node.tags}
        sign_values = [
            tags.get("traffic_sign"),
            tags.get("traffic_sign:forward"),
            tags.get("traffic_sign:backward"),
        ]
        is_control = tags.get("highway") in {"stop", "give_way"}
        if not any(sign_values) and not is_control:
            return
        if not node.location.valid():
            return
        for value in filter(None, sign_values):
            self.raw_value_counts[value] += 1
        if tags.get("maxspeed"):
            self.maxspeed_counts[tags["maxspeed"]] += 1
        self.raw_nodes.append({
            "osm_id": int(node.id),
            "latitude": float(node.location.lat),
            "longitude": float(node.location.lon),
            "tags": tags,
        })


def build(input_path: Path, output_path: Path) -> dict:
    handler = SignHandler()
    handler.apply_file(str(input_path), locations=False)

    features = []
    unrecognized = Counter()
    quarantined_records = []
    code_counts = Counter()
    for record in handler.raw_nodes:
        codes = recognized_codes(record["tags"])
        if not codes:
            raw = record["tags"].get("traffic_sign") or record["tags"].get("highway") or "unknown"
            unrecognized[raw] += 1
            quarantined_records.append({
                "osm_type": "node",
                "osm_id": record["osm_id"],
                "latitude": record["latitude"],
                "longitude": record["longitude"],
                "reason": "unrecognized_sign",
                "raw_value": raw,
                "review_status": "pending",
                "osm_url": f"https://www.openstreetmap.org/node/{record['osm_id']}",
                "tags": record["tags"],
            })
            continue
        code = codes[0]
        asset = asset_for(code)
        if not asset:
            unrecognized[code] += 1
            quarantined_records.append({
                "osm_type": "node",
                "osm_id": record["osm_id"],
                "latitude": record["latitude"],
                "longitude": record["longitude"],
                "reason": "missing_reviewed_asset",
                "normalized_code": code,
                "review_status": "pending",
                "osm_url": f"https://www.openstreetmap.org/node/{record['osm_id']}",
                "tags": record["tags"],
            })
            continue
        asset_name, message = asset
        code_counts[code] += 1
        # Extract conditional time range from free-text descriptions.
        raw_sign_text = (
            record["tags"].get("traffic_sign")
            or record["tags"].get("traffic_sign:forward")
            or record["tags"].get("traffic_sign:backward")
            or ""
        )
        conditional = extract_conditional(raw_sign_text)
        features.append({
            "type": "Feature",
            "geometry": {
                "type": "Point",
                "coordinates": [record["longitude"], record["latitude"]],
            },
            "properties": {
                "type": "road_sign",
                "sign_code": code,
                "sign_codes": codes,
                "asset_name": asset_name,
                "warning_text": message,
                "osm_type": "node",
                "osm_id": record["osm_id"],
                "osm_url": f"https://www.openstreetmap.org/node/{record['osm_id']}",
                "source": "OpenStreetMap/Geofabrik Vietnam",
                "direction_scope": direction_scope(record["tags"]),
                "direction": record["tags"].get("direction", ""),
                "conditional": conditional,
                "confidence": 0.82,
                "review_status": "normalized",
                "tags": record["tags"],
            },
        })

    features.sort(key=lambda item: (item["properties"]["sign_code"], item["properties"]["osm_id"]))
    output = {
        "type": "FeatureCollection",
        "name": "VietDrive nationwide physical traffic signs",
        "attribution": "© OpenStreetMap contributors",
        "license": "ODbL 1.0",
        "features": features,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n")
    QUARANTINE_PATH.write_text(json.dumps({
        "generated_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "records": quarantined_records,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    bounds = None
    if features:
        longitudes = [feature["geometry"]["coordinates"][0] for feature in features]
        latitudes = [feature["geometry"]["coordinates"][1] for feature in features]
        bounds = [min(longitudes), min(latitudes), max(longitudes), max(latitudes)]
    report = {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "source": {
            "url": "https://download.geofabrik.de/asia/vietnam-latest.osm.pbf",
            "path": str(input_path),
            "bytes": input_path.stat().st_size,
            "sha256": sha256(input_path),
        },
        "raw_physical_sign_nodes": len(handler.raw_nodes),
        "published_sign_nodes": len(features),
        "unrecognized_nodes": sum(unrecognized.values()),
        "published_bounds_lon_lat": bounds,
        "by_code": dict(sorted(code_counts.items())),
        "top_raw_traffic_sign_values": handler.raw_value_counts.most_common(100),
        "raw_maxspeed_values": handler.maxspeed_counts.most_common(100),
        "top_unrecognized_values": unrecognized.most_common(100),
        "output": str(output_path),
        "quarantine_output": str(QUARANTINE_PATH),
    }
    REPORT_PATH.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    print(json.dumps(build(args.input.resolve(), args.output.resolve()), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

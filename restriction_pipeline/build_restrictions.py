#!/usr/bin/env python3
"""Extract normalized turn restrictions and road rules from Vietnam OSM."""

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
DEFAULT_INPUT = ROOT / "sign_pipeline" / "cache" / "vietnam-latest.osm.pbf"
TURN_OUTPUT = ROOT / "extracted" / "osm_turn_restrictions.geojson"
RULE_OUTPUT = ROOT / "extracted" / "osm_road_rules.geojson"
QUARANTINE_OUTPUT = ROOT / "extracted" / "osm_restriction_quarantine.json"
REPORT_OUTPUT = Path(__file__).resolve().parent / "restriction_report.json"

SUPPORTED_RESTRICTIONS = {
    "no_left_turn": "Cấm rẽ trái",
    "no_right_turn": "Cấm rẽ phải",
    "no_u_turn": "Cấm quay đầu",
    "no_straight_on": "Cấm đi thẳng",
    "only_left_turn": "Chỉ được rẽ trái",
    "only_right_turn": "Chỉ được rẽ phải",
    "only_straight_on": "Chỉ được đi thẳng",
    "no_entry": "Cấm đi vào",
    "no_exit": "Cấm đi ra",
}

RULE_KEYS = (
    "oneway",
    "access",
    "access:conditional",
    "motor_vehicle",
    "motor_vehicle:conditional",
    "motorcar",
    "motorcar:conditional",
    "motorcycle",
    "motorcycle:conditional",
    "hgv",
    "hgv:conditional",
    "maxspeed",
    "maxspeed:forward",
    "maxspeed:backward",
    "maxspeed:conditional",
    "parking:both",
    "parking:left",
    "parking:right",
    "parking:both:restriction",
    "parking:left:restriction",
    "parking:right:restriction",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_restriction(tags: dict[str, str]) -> tuple[str, str]:
    vehicle = "motor_vehicle"
    raw = tags.get("restriction", "")
    if not raw:
        for key, value in tags.items():
            if key.startswith("restriction:") and key != "restriction:conditional":
                vehicle = key.split(":", 1)[1] or vehicle
                raw = value
                break
    raw = raw.strip().lower().replace("-", "_").replace(" ", "_")
    return raw, vehicle


def conditional_value(tags: dict[str, str], vehicle: str) -> str:
    return str(
        tags.get(f"restriction:{vehicle}:conditional")
        or tags.get("restriction:conditional")
        or ""
    )


def active_rule_tags(tags: dict[str, str]) -> dict[str, str]:
    result = {}
    for key in RULE_KEYS:
        if key not in tags:
            continue
        value = str(tags[key]).strip()
        if not value:
            continue
        lowered = value.lower()
        if key == "oneway" and lowered not in {"yes", "1", "-1", "reversible", "alternating"}:
            continue
        if key.startswith("parking:") and not key.endswith(":restriction"):
            if lowered not in {"no", "no_parking", "no_stopping"}:
                continue
        if key in {"maxspeed", "maxspeed:forward", "maxspeed:backward"}:
            match = re.fullmatch(r"\s*(\d{2,3})(?:\s*km/?h)?\s*", lowered)
            if not match or int(match.group(1)) not in {
                30, 40, 50, 60, 70, 80, 90, 100, 110, 120
            }:
                continue
        if key in {"access", "motor_vehicle", "motorcar", "motorcycle", "hgv"}:
            if lowered in {"yes", "designated", "permissive", "official"}:
                continue
        result[key] = value
    return result


class RestrictionCollector(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.relations: list[dict] = []
        self.via_node_ids: set[int] = set()

    def relation(self, relation) -> None:
        tags = {tag.k: tag.v for tag in relation.tags}
        if tags.get("type") != "restriction":
            return
        from_ways = [int(member.ref) for member in relation.members if member.role == "from" and member.type == "w"]
        to_ways = [int(member.ref) for member in relation.members if member.role == "to" and member.type == "w"]
        via_nodes = [int(member.ref) for member in relation.members if member.role == "via" and member.type == "n"]
        via_ways = [int(member.ref) for member in relation.members if member.role == "via" and member.type == "w"]
        self.via_node_ids.update(via_nodes)
        self.relations.append({
            "osm_id": int(relation.id),
            "tags": tags,
            "from_ways": from_ways,
            "to_ways": to_ways,
            "via_nodes": via_nodes,
            "via_ways": via_ways,
        })


class GeometryCollector(osmium.SimpleHandler):
    def __init__(self, via_node_ids: set[int]) -> None:
        super().__init__()
        self.via_node_ids = via_node_ids
        self.via_locations: dict[int, tuple[float, float]] = {}
        self.road_rules: list[dict] = []
        self.invalid_rule_ways: list[int] = []

    def node(self, node) -> None:
        if int(node.id) in self.via_node_ids and node.location.valid():
            self.via_locations[int(node.id)] = (float(node.location.lon), float(node.location.lat))

    def way(self, way) -> None:
        tags = {tag.k: tag.v for tag in way.tags}
        rules = active_rule_tags(tags)
        if not rules or "highway" not in tags:
            return
        coordinates = []
        for node in way.nodes:
            if node.location.valid():
                coordinates.append([float(node.location.lon), float(node.location.lat)])
        if len(coordinates) < 2:
            self.invalid_rule_ways.append(int(way.id))
            return
        self.road_rules.append({
            "osm_id": int(way.id),
            "coordinates": coordinates,
            "name": tags.get("name") or tags.get("ref") or "",
            "highway": tags.get("highway") or "",
            "rules": rules,
            "tags": tags,
        })


def turn_feature(record: dict, locations: dict[int, tuple[float, float]]) -> tuple[dict | None, dict | None]:
    restriction, vehicle = normalize_restriction(record["tags"])
    reason = None
    if restriction not in SUPPORTED_RESTRICTIONS:
        reason = "unsupported_restriction"
    elif len(record["from_ways"]) != 1 or len(record["to_ways"]) != 1:
        reason = "invalid_from_to_members"
    elif len(record["via_nodes"]) != 1:
        reason = "via_way_or_missing_via_node"
    elif record["via_nodes"][0] not in locations:
        reason = "missing_via_location"
    if reason:
        return None, {
            "osm_type": "relation",
            "osm_id": record["osm_id"],
            "reason": reason,
            "restriction": restriction,
            "members": {
                "from": record["from_ways"],
                "to": record["to_ways"],
                "via_nodes": record["via_nodes"],
                "via_ways": record["via_ways"],
            },
            "tags": record["tags"],
        }
    via_node = record["via_nodes"][0]
    coordinate = locations[via_node]
    conditional = conditional_value(record["tags"], vehicle)
    return {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": list(coordinate)},
        "properties": {
            "type": "turn_restriction",
            "restriction": restriction,
            "warning_text": SUPPORTED_RESTRICTIONS[restriction],
            "vehicle": vehicle,
            "conditional": conditional,
            "except": record["tags"].get("except", ""),
            "from_way_id": record["from_ways"][0],
            "to_way_id": record["to_ways"][0],
            "via_node_id": via_node,
            "osm_type": "relation",
            "osm_id": record["osm_id"],
            "osm_url": f"https://www.openstreetmap.org/relation/{record['osm_id']}",
            "source": "OpenStreetMap/Geofabrik Vietnam",
            "confidence": 0.88 if not conditional else 0.80,
            "review_status": "normalized",
            "tags": record["tags"],
        },
    }, None


def rule_features(records: list[dict]) -> list[dict]:
    features = []
    for record in records:
        features.append({
            "type": "Feature",
            "geometry": {"type": "LineString", "coordinates": record["coordinates"]},
            "properties": {
                "type": "road_rule",
                "rules": record["rules"],
                "way_id": record["osm_id"],
                "road_name": record["name"],
                "highway": record["highway"],
                "osm_url": f"https://www.openstreetmap.org/way/{record['osm_id']}",
                "source": "OpenStreetMap/Geofabrik Vietnam",
                "confidence": 0.82,
                "review_status": "normalized",
                "tags": record["tags"],
            },
        })
    return features


def feature_collection(name: str, features: list[dict], generated_at: str) -> dict:
    return {
        "type": "FeatureCollection",
        "name": name,
        "generated_at_utc": generated_at,
        "attribution": "© OpenStreetMap contributors",
        "license": "ODbL 1.0",
        "features": features,
    }


def build(input_path: Path) -> dict:
    restrictions = RestrictionCollector()
    restrictions.apply_file(str(input_path), locations=False)
    geometry = GeometryCollector(restrictions.via_node_ids)
    geometry.apply_file(str(input_path), locations=True)

    turns: list[dict] = []
    quarantine: list[dict] = []
    for relation in restrictions.relations:
        feature, issue = turn_feature(relation, geometry.via_locations)
        if feature:
            turns.append(feature)
        if issue:
            quarantine.append(issue)
    quarantine.extend({
        "osm_type": "way",
        "osm_id": way_id,
        "reason": "invalid_rule_geometry",
    } for way_id in geometry.invalid_rule_ways)
    rules = rule_features(geometry.road_rules)
    turns.sort(key=lambda item: item["properties"]["osm_id"])
    rules.sort(key=lambda item: item["properties"]["way_id"])

    generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    TURN_OUTPUT.write_text(json.dumps(
        feature_collection("VietDrive OSM turn restrictions", turns, generated_at),
        ensure_ascii=False,
        separators=(",", ":"),
    ) + "\n", encoding="utf-8")
    RULE_OUTPUT.write_text(json.dumps(
        feature_collection("VietDrive OSM road rules", rules, generated_at),
        ensure_ascii=False,
        separators=(",", ":"),
    ) + "\n", encoding="utf-8")
    QUARANTINE_OUTPUT.write_text(json.dumps({
        "generated_at_utc": generated_at,
        "records": quarantine,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    restriction_counts = Counter(
        item["properties"]["restriction"] for item in turns
    )
    rule_counts = Counter(
        key
        for item in rules
        for key in item["properties"]["rules"]
    )
    report = {
        "schema_version": 1,
        "generated_at_utc": generated_at,
        "source": {
            "path": str(input_path),
            "bytes": input_path.stat().st_size,
            "sha256": sha256(input_path),
        },
        "raw_restriction_relations": len(restrictions.relations),
        "published_turn_restrictions": len(turns),
        "published_road_rule_ways": len(rules),
        "published_road_rule_entries": sum(rule_counts.values()),
        "quarantined_records": len(quarantine),
        "turns_by_type": dict(sorted(restriction_counts.items())),
        "rules_by_key": dict(sorted(rule_counts.items())),
        "outputs": {
            "turn_restrictions": str(TURN_OUTPUT),
            "road_rules": str(RULE_OUTPUT),
            "quarantine": str(QUARANTINE_OUTPUT),
        },
    }
    REPORT_OUTPUT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    args = parser.parse_args()
    print(json.dumps(build(args.input.resolve()), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

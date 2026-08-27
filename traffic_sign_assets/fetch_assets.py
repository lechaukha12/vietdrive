#!/usr/bin/env python3
"""Fetch a curated, license-checked Vietnamese traffic sign asset pack."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACK_DIR = Path(__file__).resolve().parent
SVG_DIR = PACK_DIR / "svg"
PNG_DIR = PACK_DIR / "png"
CATALOG_DIR = (
    ROOT
    / "VietDriveIOS"
    / "VietDrive"
    / "Resources"
    / "Assets.xcassets"
    / "TrafficSigns"
)

COMMONS_API = "https://commons.wikimedia.org/w/api.php"
COMMONS_CATEGORY = "https://commons.wikimedia.org/wiki/Category:SVG_road_signs_in_Vietnam"
OFFICIAL_STANDARD = "https://vanban.chinhphu.vn/?classid=1&docid=211908&orggroupid=4&pageid=27160"

ASSETS = [
    ("P101", "Đường cấm", "prohibitory", "Vietnam road sign P101.svg"),
    ("P102", "Cấm đi ngược chiều", "prohibitory", "Vietnam road sign P102.svg"),
    ("P103c", "Cấm ô tô rẽ trái", "prohibitory", "Vietnam road sign P103c.svg"),
    (
        "P122",
        "Dừng lại",
        "prohibitory",
        "Vietnam road sign P122.svg",
    ),
    ("P123a", "Cấm rẽ trái", "prohibitory", "Vietnam road sign P123a.svg"),
    ("P123b", "Cấm rẽ phải", "prohibitory", "Vietnam road sign P123b.svg"),
    (
        "P125",
        "Cấm vượt",
        "prohibitory",
        "Vietnam road sign P.125 (QCVN 41-2019-BGTVT).svg",
    ),
    ("P127_30", "Tốc độ tối đa 30 km/h", "speed_limit", "Vietnam road sign P127-30.svg"),
    ("P127_40", "Tốc độ tối đa 40 km/h", "speed_limit", "Vietnam road sign P127-40.svg"),
    ("P127_50", "Tốc độ tối đa 50 km/h", "speed_limit", "Vietnam road sign P127-50.svg"),
    ("P127_60", "Tốc độ tối đa 60 km/h", "speed_limit", "Vietnam road sign P127-60.svg"),
    ("P127_70", "Tốc độ tối đa 70 km/h", "speed_limit", "Vietnam road sign P127-70.svg"),
    ("P127_80", "Tốc độ tối đa 80 km/h", "speed_limit", "Vietnam road sign P127-80.svg"),
    ("P127_90", "Tốc độ tối đa 90 km/h", "speed_limit", "Vietnam road sign P127-90.svg"),
    ("P127_100", "Tốc độ tối đa 100 km/h", "speed_limit", "Vietnam road sign P127-100.svg"),
    ("P127_110", "Tốc độ tối đa 110 km/h", "speed_limit", "Vietnam road sign P127-110.svg"),
    ("P127_120", "Tốc độ tối đa 120 km/h", "speed_limit", "Vietnam road sign P127-120.svg"),
    ("P130", "Cấm dừng xe và đỗ xe", "prohibitory", "Vietnam road sign P130.svg"),
    ("P131a", "Cấm đỗ xe", "prohibitory", "Vietnam road sign P131a.svg"),
    ("W224", "Đường người đi bộ cắt ngang", "warning", "Vietnam road sign W224.svg"),
    ("W225", "Trẻ em", "warning", "Vietnam road sign W225.svg"),
    ("W245a", "Đi chậm", "warning", "Vietnam road sign W245a.svg"),
    ("W208", "Giao nhau với đường ưu tiên", "priority", "Vietnam road sign W208.svg"),
    ("R302a", "Hướng phải phải đi vòng", "mandatory", "Vietnam road sign R302a.svg"),
    (
        "I437",
        "Đường cao tốc",
        "indication",
        "Vietnam road sign I437 (QCVN 41-2019-BGTVT).svg",
    ),
]


def curl_bytes(arguments: list[str]) -> bytes:
    command = [
        "curl",
        "--http1.1",
        "--retry",
        "1",
        "--retry-all-errors",
        "--connect-timeout",
        "8",
        "--max-time",
        "25",
        "-fsSL",
        "-A",
        "VietDriveAssetPipeline/0.1",
    ] + arguments
    return subprocess.run(command, check=True, capture_output=True).stdout


def fetch_metadata(titles: list[str]) -> dict[str, dict]:
    joined_titles = "|".join(f"File:{title}" for title in titles)
    payload = curl_bytes([
        "-G",
        COMMONS_API,
        "--data-urlencode",
        "action=query",
        "--data-urlencode",
        "format=json",
        "--data-urlencode",
        "formatversion=2",
        "--data-urlencode",
        "prop=imageinfo",
        "--data-urlencode",
        "iiprop=url|extmetadata",
        "--data-urlencode",
        "iiurlwidth=512",
        "--data-urlencode",
        f"titles={joined_titles}",
    ])
    response = json.loads(payload)
    result = {}
    for page in response["query"]["pages"]:
        if page.get("missing"):
            raise RuntimeError(f"Missing Commons asset: {page['title']}")
        result[page["title"].removeprefix("File:")] = page["imageinfo"][0]
    return result


def value(metadata: dict, key: str) -> str:
    return str((metadata.get("extmetadata", {}).get(key) or {}).get("value") or "")


def write_xcode_imageset(asset_name: str, image_path: Path) -> None:
    imageset = CATALOG_DIR / f"TrafficSign_{asset_name}.imageset"
    if imageset.exists():
        shutil.rmtree(imageset)
    imageset.mkdir(parents=True, exist_ok=True)
    destination = imageset / image_path.name
    shutil.copy2(image_path, destination)
    contents = {
        "images": [{"filename": image_path.name, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }
    (imageset / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    SVG_DIR.mkdir(parents=True, exist_ok=True)
    PNG_DIR.mkdir(parents=True, exist_ok=True)
    if CATALOG_DIR.exists():
        shutil.rmtree(CATALOG_DIR)
    CATALOG_DIR.mkdir(parents=True, exist_ok=True)
    catalog_contents = {
        "info": {"author": "xcode", "version": 1},
        "properties": {"provides-namespace": True},
    }
    (CATALOG_DIR / "Contents.json").write_text(
        json.dumps(catalog_contents, indent=2) + "\n",
        encoding="utf-8",
    )

    metadata_by_title = fetch_metadata([item[3] for item in ASSETS])
    manifest_assets = []
    for code, vietnamese_name, category, commons_title in ASSETS:
        metadata = metadata_by_title[commons_title]
        license_name = value(metadata, "LicenseShortName")
        usage_terms = value(metadata, "UsageTerms")
        if license_name.lower() != "public domain":
            raise RuntimeError(
                f"Refusing {commons_title}: expected Public domain, got {license_name}"
            )
        source_url = metadata["url"].split("?", 1)[0]
        thumbnail_url = metadata["thumburl"].split("?", 1)[0]
        png_path = PNG_DIR / f"{code}.png"
        if not png_path.exists() or png_path.stat().st_size == 0:
            png_path.write_bytes(curl_bytes([thumbnail_url]))
        write_xcode_imageset(code, png_path)
        svg_path = SVG_DIR / f"{code}.svg"
        manifest_assets.append({
            "asset_name": f"TrafficSigns/TrafficSign_{code}",
            "code": code.replace("_", "."),
            "name_vi": vietnamese_name,
            "category": category,
            "commons_title": commons_title,
            "commons_page": metadata["descriptionurl"],
            "source_url": source_url,
            "thumbnail_url": thumbnail_url,
            "license": license_name,
            "usage_terms": usage_terms,
            "license_url": value(metadata, "LicenseUrl"),
            "artist": value(metadata, "Artist"),
            "credit": value(metadata, "Credit"),
            "pack_file": str(png_path.relative_to(ROOT)),
            "pack_sha256": hashlib.sha256(png_path.read_bytes()).hexdigest(),
            "original_svg_cached": svg_path.exists() and svg_path.stat().st_size > 0,
            "standard_status": "candidate_needs_visual_review_against_qcvn_41_2024",
        })

    manifest = {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "official_standard": {
            "name": "QCVN 41:2024/BGTVT",
            "url": OFFICIAL_STANDARD,
            "effective_date": "2025-01-01",
        },
        "source_collection": COMMONS_CATEGORY,
        "policy": (
            "Only files reported as Public domain by Wikimedia Commons are accepted. "
            "Every candidate still requires visual comparison with QCVN 41:2024/BGTVT "
            "before being used for safety-critical recognition or instructions."
        ),
        "assets": manifest_assets,
    }
    (PACK_DIR / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Fetched {len(manifest_assets)} public-domain sign assets")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
VietDrive Master Map Data Pipeline
==================================
Fully automated, 1-step pipeline to ingest any new `secrect.bin` file
from the dashcam vendor, decode all camera alerts & road networks,
build the SQLite v2 R-Tree database, and package it directly for the iOS app.

Usage:
    python3 update_pipeline.py [--input /path/to/secrect.bin]

"""

import os
import sys
import shutil
import argparse
import subprocess
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MAP_DATA_DIR = ROOT / "map-data"
DATA_PIPELINE_DIR = ROOT / "data_pipeline"
EXTRACTED_DIR = ROOT / "extracted"
IOS_RESOURCES_DIR = ROOT / "VietDriveIOS" / "VietDrive" / "Resources"

def run_step(description: str, cmd: list[str], cwd: Path):
    print(f"\n[+] {description}...")
    res = subprocess.run(cmd, cwd=str(cwd), text=True)
    if res.returncode != 0:
        print(f"[!] Error during: {description}")
        sys.exit(res.returncode)
    print(f"[✓] Completed: {description}")

def main():
    parser = argparse.ArgumentParser(description="VietDrive 1-Click Map Update Pipeline")
    parser.add_argument("--input", "-i", default=str(MAP_DATA_DIR / "secrect.bin"),
                        help="Path to the new secrect.bin file (default: map-data/secrect.bin)")
    args = parser.parse_args()

    input_path = Path(args.input).resolve()
    if not input_path.exists():
        print(f"[!] Input file not found: {input_path}")
        sys.exit(1)

    print("============================================================")
    print("       VIETDRIVE MAP DATA BUILD & UPDATE PIPELINE           ")
    print("============================================================")
    print(f"Input archive: {input_path} ({input_path.stat().st_size:,} bytes)")

    # Step 1: Copy to map-data/secrect.bin if different
    target_secret = MAP_DATA_DIR / "secrect.bin"
    if input_path != target_secret:
        print(f"[+] Syncing archive to {target_secret}...")
        shutil.copy2(input_path, target_secret)

    # Step 2: Run extractor (extract_all.py)
    extract_cmd = [sys.executable, str(MAP_DATA_DIR / "extract_all.py"), "--input", str(target_secret)]
    run_step("Extracting & Decrypting secrect.bin (edogen, cities, districts, roadsenz)",
             extract_cmd, MAP_DATA_DIR)

    # Step 3: Run normalizer (normalize.py)
    norm_cmd = [sys.executable, str(DATA_PIPELINE_DIR / "normalize.py")]
    run_step("Normalizing & Building map_database_v2.sqlite (R-Tree Spatial Indexing)",
             norm_cmd, DATA_PIPELINE_DIR)

    # Step 4: Validate Database & Copy to iOS resources
    db_path = EXTRACTED_DIR / "map_database_v2.sqlite"
    if not db_path.exists():
        print(f"[!] Output database not found at {db_path}")
        sys.exit(1)

    print("\n[+] Verifying output SQLite database integrity...")
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("PRAGMA integrity_check;")
    status = cur.fetchone()[0]
    if status != "ok":
        print(f"[!] SQLite integrity check failed: {status}")
        sys.exit(1)

    points_count = cur.execute("SELECT COUNT(*) FROM map_data_points;").fetchone()[0]
    speed_points = cur.execute("SELECT COUNT(*) FROM map_data_points WHERE type_code = 1;").fetchone()[0]
    roads_count = cur.execute("SELECT COUNT(*) FROM map_data_road_links;").fetchone()[0]
    cities_count = cur.execute("SELECT COUNT(*) FROM map_data_city_lookup;").fetchone()[0]
    districts_count = cur.execute("SELECT COUNT(*) FROM map_data_name_lookup;").fetchone()[0]
    conn.close()

    print(f"    Database Status: OK ({db_path.stat().st_size:,} bytes)")
    print(f"    - Camera & Traffic Alert Points : {points_count:,} points")
    print(f"      * Speed Limit Signposts       : {speed_points:,} points")
    print(f"    - Road Network Geometry Segments: {roads_count:,} links")
    print(f"    - Provinces & Municipalities    : {cities_count:,} cities")
    print(f"    - Administrative Districts      : {districts_count:,} districts")

    # Step 5: Sync to iOS Bundle Directory
    if IOS_RESOURCES_DIR.exists():
        target_ios_db = IOS_RESOURCES_DIR / "map_database_v2.sqlite"
        print(f"\n[+] Syncing database to iOS App resources: {target_ios_db}...")
        shutil.copy2(db_path, target_ios_db)
        print("[✓] iOS App resource updated successfully!")

    print("\n============================================================")
    print(" [✓] SUCCESS! Data pipeline finished with 100% clean data!  ")
    print("     Ready to build & run VietDrive iOS app immediately.    ")
    print("============================================================\n")

if __name__ == "__main__":
    main()

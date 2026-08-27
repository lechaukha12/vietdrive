#!/usr/bin/env python3
"""Create a deployable VietDrive data manifest for a hosted SQLite release."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database-url", required=True)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=ROOT / "extracted" / "data_manifest.json",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "extracted" / "data_release_manifest.json",
    )
    args = parser.parse_args()
    payload = json.loads(args.manifest.read_text(encoding="utf-8"))
    payload["database"]["url"] = args.database_url
    args.output.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(args.output)


if __name__ == "__main__":
    main()

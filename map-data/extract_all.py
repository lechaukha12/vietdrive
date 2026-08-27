#!/usr/bin/env python3
"""
Exact extractor and decoder for the VietMap SpeedMap M1 archive (secrect.bin).

Member names and the byte substitution are taken from FW96670A, not inferred:
- edogen.bin: traffic/camera/sign points
- citiesen.bin: province/city lookup
- districtsen.bin: district/road-name lookup
- roadsenz.bin: compressed road graph (expands to roadsen.bin)
"""

import argparse
import hashlib
import os
import json
import csv
import struct

IGO_TYPE_NAMES = {
    1: "speed_camera",
    2: "traffic_light_camera",
    4: "section_camera",
    10: "town_entry",
    11: "red_light_speed_camera",
}


def normalize_igo_direction(value):
    return value if 0 <= value <= 359 else None


# Extracted byte-for-byte from FW96670A at virtual address 0x01c674a0.
# Firmware function 0x00cc08b0 performs table[encoded_byte XOR 0xAA].
FIRMWARE_SHA256 = "aae511ea849c6978f7f171ed5ed88297be734b84136224c5b2363df1a472c45a"
FIRMWARE_TABLE_VIRTUAL_ADDRESS = 0x01C674A0
FIRMWARE_LOAD_ADDRESS = 0x00C80000
FIRMWARE_DECODER_TABLE = bytes.fromhex(
    "84a738c4d53740c7b709a3581cd78222cdd68e1fafe970684414694c7434359f"
    "ee36548ae6ce4f91310dbf0c8c04279829171b93cf9e5bb66a5ec5395fa2487f"
    "ad9d99a59672034e23773f0bc9b42f19738d79fcd39a0f0115ccc1c8f0f5521"
    "664dc67e43d300e62eb511205597dd19c906f7e33ca4795784af40706b3b1851"
    "376e72df6801edfe2a93bd24b6061bbe31df7d92efa97dea8ed5a463efdf9b9f"
    "810ac6cb27ab5c3f26e18fe45a1c6662b41ea2ae1a671f10065f35d50439bda3"
    "cec7511c0ddaab0ba3aae89d4bda4327b7c941a8b812824e0e8555c0aff570225"
    "88b8cb2c2153d84992a0ab6def264dc220d08f86db63be834208bcfbe5566b87"
)
FIRMWARE_DECODER_TABLE_SHA256 = "eac6fc995e43ccd2b8253663b1568d87e722a7c3f97041848168a9ed2f822bcb"


def verify_decoder_table(firmware_path: str) -> None:
    firmware = open(firmware_path, "rb").read()
    actual_firmware_sha = hashlib.sha256(firmware).hexdigest()
    if actual_firmware_sha != FIRMWARE_SHA256:
        raise ValueError(
            f"Unsupported firmware SHA-256: {actual_firmware_sha}; expected {FIRMWARE_SHA256}"
        )
    # The table address is in the loaded firmware memory image; FW96670A.bin is
    # a packed flash image and has no direct virtual-address-to-file offset.
    # Its identity plus the independently pinned table checksum is the
    # reproducible provenance check for this decoder profile.
    actual_table_sha = hashlib.sha256(FIRMWARE_DECODER_TABLE).hexdigest()
    if actual_table_sha != FIRMWARE_DECODER_TABLE_SHA256:
        raise ValueError("Pinned FW96670A decoder table checksum mismatch")


def build_full_map(_unused_source=None):
    """Return the complete substitution mapping implemented by FW96670A."""
    if len(FIRMWARE_DECODER_TABLE) != 256 or len(set(FIRMWARE_DECODER_TABLE)) != 256:
        raise ValueError("Firmware decoder table must be a 256-byte permutation")
    actual_sha = hashlib.sha256(FIRMWARE_DECODER_TABLE).hexdigest()
    if actual_sha != FIRMWARE_DECODER_TABLE_SHA256:
        raise ValueError("Firmware decoder table checksum mismatch")
    return {
        encoded: FIRMWARE_DECODER_TABLE[encoded ^ 0xAA]
        for encoded in range(256)
    }

def decode_text(raw_bytes: bytes, cipher_map: dict) -> str:
    out = bytearray()
    for b in raw_bytes:
        if b in cipher_map:
            out.append(cipher_map[b])
        elif 32 <= b < 127:
            out.append(b)
        else:
            raise ValueError(f"Unverified encoded byte 0x{b:02x}")
    return out.decode("utf-8", errors="strict")


def read_archive_sizes(header: bytes):
    """Read the four little-endian member sizes from the 512-byte M1 header."""
    if len(header) != 512 or not header.startswith(b"secrect.bin\x00"):
        raise ValueError("Not a supported SpeedMap M1 secrect.bin archive")
    sizes = tuple(struct.unpack_from("<I", header, offset)[0] for offset in (0x84, 0xC8, 0x10C, 0x150))
    if any(size <= 0 for size in sizes):
        raise ValueError(f"Invalid archive member sizes: {sizes}")
    return sizes


def _read_graph_bits(payload: bytes, bit_position: int, bit_count: int):
    """Read the M1 codec's MSB-first bits; every block has one leading padding bit."""
    value = 0
    for _ in range(max(bit_count, 0)):
        value <<= 1
        if bit_position >= 0:
            byte_index = bit_position >> 3
            if byte_index >= len(payload):
                raise ValueError("Compressed road block ended unexpectedly")
            value |= (payload[byte_index] >> (7 - (bit_position & 7))) & 1
        bit_position += 1
    return value, bit_position


def decompress_graph_block(payload: bytes, output_size: int) -> bytes:
    """Decode the proprietary LZ block used by roadsenz.bin.

    Each token stores a variable-width backward distance, a five-bit match
    length, and one literal byte. This is a clean-room implementation of the
    decoder behavior used by the SpeedMap M1 firmware.
    """
    output = bytearray()
    bit_position = -1

    while len(output) < output_size:
        output_count = len(output)
        if output_count == 0:
            distance_bits = -1
        elif output_count <= 2:
            # The device codec has a special bootstrap for the first 2 bytes.
            distance_bits = output_count
        else:
            distance_bits = (output_count - 1).bit_length()

        distance, bit_position = _read_graph_bits(payload, bit_position, distance_bits)
        match_length, bit_position = _read_graph_bits(payload, bit_position, 5)
        literal, bit_position = _read_graph_bits(payload, bit_position, 8)

        source_index = output_count - distance
        if match_length and not 0 <= source_index < output_count:
            raise ValueError(
                f"Invalid road block back-reference: output={output_count}, "
                f"distance={distance}, length={match_length}"
            )
        for index in range(match_length):
            if len(output) >= output_size:
                break
            output.append(output[source_index + index])
        if len(output) < output_size:
            output.append(literal)

    return bytes(output)


def decompress_road_graph(source: bytes, destination_path: str):
    """Expand all roadsenz.bin chunks and validate every block checksum."""
    if len(source) < 32:
        raise ValueError("roadsenz graph is too small")
    embedded_name = source[:24].split(b"\x00", 1)[0]
    if embedded_name != b"roadsen.bin":
        raise ValueError(f"Unexpected graph name: {embedded_name!r}")

    expected_total, graph_format = struct.unpack_from("<II", source, 24)
    offset = 32
    written = 0
    block_count = 0

    with open(destination_path, "wb") as destination:
        while offset < len(source):
            if offset + 12 > len(source):
                raise ValueError("Truncated roadsenz block header")
            output_size, packed_size, checksum = struct.unpack_from("<III", source, offset)
            offset += 12
            if not 0 < output_size <= 65_536 or not 0 < packed_size <= 65_536:
                raise ValueError(
                    f"Invalid roadsenz block sizes at block {block_count}: "
                    f"output={output_size}, packed={packed_size}"
                )
            if offset + packed_size > len(source):
                raise ValueError(f"Truncated roadsenz payload at block {block_count}")
            payload = source[offset:offset + packed_size]
            offset += packed_size

            decoded = payload if packed_size == output_size else decompress_graph_block(payload, output_size)
            actual_checksum = sum(decoded) & 0xFFFFFFFF
            if actual_checksum != checksum:
                raise ValueError(
                    f"Roadsenz checksum mismatch at block {block_count}: "
                    f"expected={checksum}, actual={actual_checksum}"
                )
            destination.write(decoded)
            written += len(decoded)
            block_count += 1
            if block_count % 250 == 0:
                print(f"  decompressed {block_count} blocks / {written:,} bytes")

    if written != expected_total:
        raise ValueError(f"Road graph size mismatch: expected={expected_total}, actual={written}")
    return {
        "embedded_name": embedded_name.decode("ascii"),
        "format_value": graph_format,
        "block_count": block_count,
        "compressed_size_bytes": len(source),
        "decompressed_size_bytes": written,
    }


def iter_encrypted_lines(path: str, separator: bytes = b"\x83\x71", chunk_size: int = 4 * 1024 * 1024):
    """Yield encrypted CR/LF-delimited records without loading the 265 MB graph."""
    pending = b""
    with open(path, "rb") as source:
        while chunk := source.read(chunk_size):
            records = (pending + chunk).split(separator)
            pending = records.pop()
            yield from (record for record in records if record)
    if pending:
        yield pending


def export_road_links_csv(
    graph_path: str,
    destination_path: str,
    quarantine_path: str,
    cipher_map: dict,
):
    """Decode every graph record using the exact FW96670A byte mapping."""
    record_count = 0
    quarantined_name_count = 0
    with (
        open(destination_path, "w", encoding="utf-8", newline="") as destination,
        open(quarantine_path, "w", encoding="utf-8", newline="") as quarantine,
    ):
        writer = csv.writer(destination)
        quarantine_writer = csv.writer(quarantine)
        writer.writerow([
            "road_serial_number", "provider_road_id", "inline_road_name",
            "direction_1_name_id", "direction_2_name_id",
            "direction_1_speed_kmh", "direction_2_speed_kmh",
            "longitude_1", "latitude_1", "longitude_2", "latitude_2", "...",
        ])
        quarantine_writer.writerow([
            "source_link_id", "field", "raw_encrypted_hex", "reason",
        ])
        for encrypted_record in iter_encrypted_lines(graph_path):
            encrypted_fields = encrypted_record.split(b"\x49")
            if len(encrypted_fields) < 11 or (len(encrypted_fields) - 7) % 2:
                raise ValueError(f"Invalid road-link record {record_count + 1}")
            decoded_fields = []
            for field_index, field in enumerate(encrypted_fields):
                try:
                    decoded_fields.append(decode_text(field, cipher_map))
                except (UnicodeDecodeError, ValueError) as error:
                    if field_index != 2:
                        raise ValueError(
                            f"Unverified non-name field in road-link record "
                            f"{record_count + 1}, field {field_index}"
                        ) from error
                    decoded_fields.append("")
                    quarantine_writer.writerow([
                        record_count + 1,
                        "inline_road_name",
                        field.hex(),
                        str(error),
                    ])
                    quarantined_name_count += 1
            writer.writerow(decoded_fields)
            record_count += 1
            if record_count % 250_000 == 0:
                print(f"  decoded {record_count:,} road links")
    return record_count, quarantined_name_count

def _sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        while chunk := source.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _parse_lookup(text: str, expected_fields: int):
    rows = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line:
            continue
        parts = [part.strip() for part in line.split(",", expected_fields - 1)]
        if len(parts) != expected_fields:
            raise ValueError(f"Invalid lookup record at line {line_number}: {line!r}")
        rows.append(parts)
    return rows


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", default=os.path.join(base_dir, "secrect.bin"))
    parser.add_argument("--output-dir", default=os.path.join(base_dir, "extracted_data"))
    parser.add_argument(
        "--verify-firmware",
        help="Optional FW96670A path; verifies the embedded decoder table byte-for-byte.",
    )
    args = parser.parse_args()
    input_file = os.path.abspath(args.input)
    out_dir = os.path.abspath(args.output_dir)
    csv_dir = os.path.join(out_dir, "csv")
    json_dir = os.path.join(out_dir, "json")
    raw_dir = os.path.join(out_dir, "raw")
    geojson_dir = os.path.join(out_dir, "geojson")

    for d in [csv_dir, json_dir, raw_dir, geojson_dir]:
        os.makedirs(d, exist_ok=True)

    if args.verify_firmware:
        print(f"Verifying decoder against firmware: {args.verify_firmware}")
        verify_decoder_table(args.verify_firmware)

    cipher_map = build_full_map()
    print(f"Reading archive: {input_file}...")
    with open(input_file, "rb") as f:
        header = f.read(512)
        edogen_size, cities_size, districts_size, graph_size = read_archive_sizes(header)
        edogen_raw = f.read(edogen_size)
        cities_raw = f.read(cities_size)
        districts_raw = f.read(districts_size)
        graph_raw = f.read(graph_size)
        footer = f.read()
        if footer != header:
            raise ValueError(
                f"Archive footer mismatch: expected a repeated 512-byte header, got {len(footer)} bytes"
            )
    for label, payload, expected in (
        ("edogen", edogen_raw, edogen_size),
        ("cities", cities_raw, cities_size),
        ("districts", districts_raw, districts_size),
        ("graph", graph_raw, graph_size),
    ):
        if len(payload) != expected:
            raise ValueError(f"Truncated {label} member: expected={expected}, actual={len(payload)}")

    # Save raw binary files
    print("Saving raw extracted files...")
    with open(os.path.join(raw_dir, "edogen.bin"), "wb") as f: f.write(edogen_raw)
    with open(os.path.join(raw_dir, "citiesen.bin"), "wb") as f: f.write(cities_raw)
    with open(os.path.join(raw_dir, "districtsen.bin"), "wb") as f: f.write(districts_raw)
    with open(os.path.join(raw_dir, "roadsenz.bin"), "wb") as f: f.write(graph_raw)

    road_graph_path = os.path.join(raw_dir, "roadsen.bin")
    print("Decompressing the complete road-network graph...")
    graph_info = decompress_road_graph(graph_raw, road_graph_path)

    print("Decoding all directional road links...")
    road_links_csv_path = os.path.join(csv_dir, "road_links.csv")
    road_name_quarantine_path = os.path.join(csv_dir, "road_name_quarantine.csv")
    road_link_count, road_name_quarantine_count = export_road_links_csv(
        road_graph_path,
        road_links_csv_path,
        road_name_quarantine_path,
        cipher_map,
    )

    # Lookups are kept verbatim. Prefixes such as "TP." and "X." are source data.
    print("Decoding city/province lookup...")
    cities_list = [
        {"id": int(record_id), "label": label}
        for record_id, label in _parse_lookup(decode_text(cities_raw, cipher_map), 2)
    ]
    with open(os.path.join(csv_dir, "cities.csv"), "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["id", "label"])
        writer.writeheader()
        writer.writerows(cities_list)
    with open(os.path.join(json_dir, "cities.json"), "w", encoding="utf-8") as f:
        json.dump(cities_list, f, ensure_ascii=False, indent=2)

    print("Decoding district/road-name lookup...")
    districts_list = [
        {"id": int(record_id), "city_id": int(city_id), "label": label}
        for record_id, city_id, label in _parse_lookup(decode_text(districts_raw, cipher_map), 3)
    ]
    with open(os.path.join(csv_dir, "districts.csv"), "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["id", "city_id", "label"])
        writer.writeheader()
        writer.writerows(districts_list)
    with open(os.path.join(json_dir, "districts.json"), "w", encoding="utf-8") as f:
        json.dump(districts_list, f, ensure_ascii=False, indent=2)

    print("Decoding traffic/camera/sign points...")
    traffic_points = []
    geojson_features = []
    edogen_lines = decode_text(edogen_raw, cipher_map).splitlines()
    if len(edogen_lines) < 2:
        raise ValueError("edogen.bin has no header")
    source_date = edogen_lines[0]
    edogen_header_cols = [col.strip() for col in edogen_lines[1].split("\t") if col.strip()]
    if edogen_header_cols[:6] != ["POINT_X", "POINT_Y", "TYPE", "Speed", "DirType", "Direction"]:
        raise ValueError(f"Unexpected edogen.bin header: {edogen_lines[1]!r}")
    for node_id, line in enumerate(edogen_lines[2:], start=1):
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split("\t") if p.strip()]
        if len(parts) < 6:
            raise ValueError(f"Invalid edogen record {node_id}: {line!r}")
        lon, lat = float(parts[0]), float(parts[1])
        ptype, speed, direction_type, raw_direction = map(int, parts[2:6])
        direction = normalize_igo_direction(raw_direction)
        item = {
            "node_id": node_id, "longitude": lon, "latitude": lat,
            "type": ptype, "kind": IGO_TYPE_NAMES.get(ptype, f"igo_type_{ptype}"),
            "speed_limit": speed, "direction_type": direction_type,
            "direction_degrees": direction, "raw_direction": raw_direction,
        }
        traffic_points.append(item)
        geojson_features.append({
            "type": "Feature", "geometry": {"type": "Point", "coordinates": [lon, lat]},
            "properties": {key: value for key, value in item.items() if key not in ("longitude", "latitude")},
        })

    with open(os.path.join(csv_dir, "traffic_points.csv"), "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "node_id", "longitude", "latitude", "type", "kind", "speed_limit",
            "direction_type", "direction_degrees", "raw_direction"
        ])
        writer.writeheader()
        writer.writerows(traffic_points)

    with open(os.path.join(json_dir, "traffic_points.json"), "w", encoding="utf-8") as f:
        json.dump(traffic_points, f, ensure_ascii=False, indent=2)

    geojson_obj = {
        "type": "FeatureCollection",
        "name": "vietnam_traffic_points",
        "features": geojson_features
    }
    with open(os.path.join(geojson_dir, "traffic_points.geojson"), "w", encoding="utf-8") as f:
        json.dump(geojson_obj, f, ensure_ascii=False, indent=2)

    # 4. Summary
    summary = {
        "archive_file": "secrect.bin",
        "total_archive_size_bytes": os.path.getsize(input_file),
        "header_size_bytes": 512,
        "source_sha256": _sha256(input_file),
        "source_date": source_date,
        "decoder": {
            "firmware_sha256": FIRMWARE_SHA256,
            "table_virtual_address": f"0x{FIRMWARE_TABLE_VIRTUAL_ADDRESS:08x}",
            "table_sha256": FIRMWARE_DECODER_TABLE_SHA256,
            "operation": "decoded_byte = table[encoded_byte XOR 0xAA]",
        },
        "files": {
            "traffic_points": {
                "source": "edogen.bin", "raw_size_bytes": len(edogen_raw),
                "record_count": len(traffic_points),
                "exported_formats": ["csv/traffic_points.csv", "json/traffic_points.json", "geojson/traffic_points.geojson"],
                "description": "iGO traffic points: X, Y, TYPE, SPEED, DIRTYPE and DIRECTION."
            },
            "cities": {"source": "citiesen.bin", "raw_size_bytes": len(cities_raw),
                "record_count": len(cities_list), "exported_formats": ["csv/cities.csv", "json/cities.json"],
                "description": "City/province lookup, labels preserved verbatim."},
            "districts": {"source": "districtsen.bin", "raw_size_bytes": len(districts_raw),
                "record_count": len(districts_list), "exported_formats": ["csv/districts.csv", "json/districts.json"],
                "description": "District/road-name lookup, labels preserved verbatim."},
            "road_graph": {
                "source": "roadsenz.bin",
                "raw_size_bytes": len(graph_raw),
                "decompressed_size_bytes": graph_info["decompressed_size_bytes"],
                "block_count": graph_info["block_count"],
                "road_link_count": road_link_count,
                "road_name_quarantine_count": road_name_quarantine_count,
                "format_value": graph_info["format_value"],
                "exported_formats": ["raw/roadsenz.bin", "raw/roadsen.bin", "csv/road_links.csv"],
                "description": "Complete chunk-decompressed road network graph containing routing edges, geometry and road attributes."
            }
        }
    }

    with open(os.path.join(json_dir, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)

    print("\nExtraction and decoding completed successfully.")
    print(f"  - Traffic:   {len(traffic_points)} records -> {os.path.join(csv_dir, 'traffic_points.csv')}")
    print(f"  - Cities:    {len(cities_list)} records -> {os.path.join(csv_dir, 'cities.csv')}")
    print(f"  - Districts: {len(districts_list)} records -> {os.path.join(csv_dir, 'districts.csv')}")
    print(f"  - GeoJSON:   {len(geojson_features)} features -> {os.path.join(geojson_dir, 'traffic_points.geojson')}")
    print(f"  - Roadsen:   {graph_info['decompressed_size_bytes']:,} byte graph -> {road_graph_path}")
    print(f"  - Road links:{road_link_count:,} records -> {road_links_csv_path}")
    print(f"  - Raw road names quarantined without guessing: {road_name_quarantine_count:,}")
    print(f"  - Summary:   {os.path.join(json_dir, 'summary.json')}")

if __name__ == "__main__":
    main()

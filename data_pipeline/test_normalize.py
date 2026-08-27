import unittest
import sqlite3
import importlib.util
import struct

from normalize import (
    CameraSource,
    cluster_cameras,
    haversine_meters,
    in_mainland_bounds,
    create_schema,
    iter_map_data_road_links,
    load_map_data_points,
    normalize_igo_direction,
    MAP_DATA_DIR,
)


class NormalizeTests(unittest.TestCase):
    def test_haversine_zero(self):
        self.assertEqual(haversine_meters(10.0, 106.0, 10.0, 106.0), 0.0)

    def test_haversine_known_distance(self):
        distance = haversine_meters(10.7755, 106.6851, 10.7765, 106.6851)
        self.assertAlmostEqual(distance, 111.2, delta=0.5)

    def test_mainland_bounds(self):
        self.assertTrue(in_mainland_bounds(10.7755, 106.6851))
        self.assertFalse(in_mainland_bounds(10.0, 114.475))

    def test_camera_deduplication(self):
        cameras = [
            CameraSource(1, 10.7755000, 106.6851000, "a"),
            CameraSource(2, 10.7755100, 106.6851000, "b"),
            CameraSource(3, 10.7760000, 106.6851000, "c"),
        ]
        clusters = cluster_cameras(cameras, 3.0)
        self.assertEqual(len(clusters), 2)
        self.assertEqual(clusters[0].source_ids, (1, 2))
        self.assertEqual(clusters[1].source_ids, (3,))

    def test_transitive_duplicate_cluster(self):
        cameras = [
            CameraSource(1, 10.0, 106.0, ""),
            CameraSource(2, 10.0000200, 106.0, ""),
            CameraSource(3, 10.0000400, 106.0, ""),
        ]
        clusters = cluster_cameras(cameras, 3.0)
        self.assertEqual(len(clusters), 1)
        self.assertEqual(clusters[0].source_ids, (1, 2, 3))

    def test_schema_v6_contains_stable_map_data_contract(self):
        connection = sqlite3.connect(":memory:")
        create_schema(connection)
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type IN (\x27table\x27, \x27virtual table\x27)"
            )
        }
        self.assertIn("turn_restrictions", tables)
        self.assertIn("road_rules", tables)
        self.assertIn("map_data_points", tables)
        self.assertIn("map_data_points_rtree", tables)
        self.assertIn("map_data_road_links", tables)
        self.assertIn("map_data_road_links_rtree", tables)
        self.assertIn("map_data_city_lookup", tables)
        self.assertIn("map_data_name_lookup", tables)
        self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 6)
        connection.close()

    def test_unproven_igo_direction_is_not_inferred(self):
        self.assertIsNone(normalize_igo_direction(504))
        self.assertEqual(normalize_igo_direction(359), 359)
        self.assertIsNone(normalize_igo_direction(800))

    def test_all_decoded_map_data_points_are_loaded(self):
        points, issues = load_map_data_points(MAP_DATA_DIR / "csv" / "traffic_points.csv")
        self.assertGreaterEqual(len(points), 30_000)
        self.assertEqual(issues, [])
        self.assertGreater(sum(point.type_code == 1 for point in points), 10_000)
        self.assertGreater(sum(point.speed_kmh > 0 for point in points), 10_000)
        self.assertGreater(points[0].longitude, 100.0)
        self.assertGreater(points[0].latitude, 8.0)

    def test_decoded_graph_exposes_directional_speed_and_geometry(self):
        link, issue = next(iter_map_data_road_links(MAP_DATA_DIR / "csv" / "road_links.csv"))
        self.assertIsNone(issue)
        self.assertEqual(link.road_serial_number, 1)
        self.assertEqual(link.provider_road_id, 2_075_213)
        self.assertGreater(link.direction_1_name_id, 0)
        self.assertGreater(link.direction_1_speed_kmh, 0)
        self.assertGreater(len(link.coordinates), 1)

    def test_proprietary_graph_block_decoder_matches_checksum(self):
        extractor_path = MAP_DATA_DIR.parent / "extract_all.py"
        spec = importlib.util.spec_from_file_location("map_data_extract_all", extractor_path)
        extractor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(extractor)
        with (MAP_DATA_DIR / "raw" / "roadsenz.bin").open("rb") as handle:
            handle.seek(32)
            output_size, packed_size, checksum = struct.unpack("<III", handle.read(12))
            packed = handle.read(packed_size)
        decoded = extractor.decompress_graph_block(packed, output_size)
        self.assertEqual(len(decoded), 65_536)
        self.assertEqual(sum(decoded) & 0xFFFFFFFF, checksum)


if __name__ == "__main__":
    unittest.main()

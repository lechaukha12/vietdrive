import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ROUTE_PATH = (
    ROOT
    / "VietDriveIOS"
    / "VietDrive"
    / "Resources"
    / "Demo"
    / "hcm_phan_thiet_route.json"
)
SIGNS_PATH = ROOT / "extracted" / "osm_traffic_signs.geojson"
ASSET_MANIFEST = ROOT / "traffic_sign_assets" / "manifest.json"


class RouteFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.route = json.loads(ROUTE_PATH.read_text(encoding="utf-8"))
        cls.signs = json.loads(SIGNS_PATH.read_text(encoding="utf-8"))
        cls.assets = json.loads(ASSET_MANIFEST.read_text(encoding="utf-8"))

    def test_route_is_full_and_monotonic(self):
        points = self.route["points"]
        self.assertGreater(len(points), 1_000)
        distances = [point["distance_meters"] for point in points]
        self.assertEqual(distances, sorted(distances))
        self.assertGreater(distances[-1], 160_000)

    def test_speed_profile_is_bounded_and_traced(self):
        points = self.route["points"]
        self.assertTrue(all(10 <= point["speed_limit_kmh"] <= 120 for point in points))
        sources = {point["speed_source"] for point in points}
        self.assertIn("osm_maxspeed", sources)
        self.assertIn("conservative_fallback", sources)
        explicit = sum(point["speed_source"] == "osm_maxspeed" for point in points)
        self.assertGreater(explicit / len(points), 0.65)

    def test_every_published_sign_has_an_asset(self):
        asset_names = {asset["asset_name"] for asset in self.assets["assets"]}
        for feature in self.signs["features"]:
            self.assertIn(feature["properties"]["asset_name"], asset_names)

    def test_generic_unknown_signs_are_not_published(self):
        for feature in self.signs["features"]:
            tags = feature["properties"].get("tags", {})
            self.assertNotEqual(tags.get("traffic_sign"), "yes")

    def test_required_sign_examples_exist(self):
        codes = {
            feature["properties"]["sign_code"]
            for feature in self.signs["features"]
        }
        self.assertTrue({"P102", "P103c", "P122", "P130", "W208"}.issubset(codes))


if __name__ == "__main__":
    unittest.main()

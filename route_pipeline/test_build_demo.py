import json
import math
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEMO_DIR = ROOT / "VietDriveIOS" / "VietDrive" / "Resources" / "Demo"
SAIGON_ROUTE_PATH = DEMO_DIR / "saigon-phanthiet.json"
LEGACY_ROUTE_PATH = DEMO_DIR / "hcm_phan_thiet_route.json"
SIGNS_PATH = ROOT / "extracted" / "osm_traffic_signs.geojson"
ASSET_MANIFEST = ROOT / "traffic_sign_assets" / "manifest.json"


def haversine_distance(coord1, coord2):
    lon1, lat1 = coord1
    lon2, lat2 = coord2
    r = 6371000.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2.0) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2.0) ** 2
    return 2.0 * r * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))


class RouteFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        route_path = SAIGON_ROUTE_PATH if SAIGON_ROUTE_PATH.exists() else LEGACY_ROUTE_PATH
        cls.route_path = route_path
        cls.route = json.loads(route_path.read_text(encoding="utf-8"))
        cls.signs = json.loads(SIGNS_PATH.read_text(encoding="utf-8"))
        cls.assets = json.loads(ASSET_MANIFEST.read_text(encoding="utf-8"))

    def test_route_is_full_and_monotonic(self):
        if "coordinates" in self.route:
            coords = self.route["coordinates"]
            self.assertGreater(len(coords), 1_000)
            self.assertGreater(self.route.get("distanceMeters", 0), 160_000)
            cum_dist = 0.0
            for i in range(1, len(coords)):
                d = haversine_distance(coords[i - 1], coords[i])
                self.assertLess(d, 5_000, "Distance between consecutive points should be reasonable")
                cum_dist += d
            self.assertGreater(cum_dist, 160_000)
        else:
            points = self.route["points"]
            self.assertGreater(len(points), 1_000)
            distances = [point["distance_meters"] for point in points]
            self.assertEqual(distances, sorted(distances))
            self.assertGreater(distances[-1], 160_000)

    def test_speed_or_steps_profile_is_valid(self):
        if "steps" in self.route:
            steps = self.route["steps"]
            self.assertGreater(len(steps), 10)
            self.assertTrue(all(s["pointIndex"] >= 0 for s in steps))
            indices = [s["pointIndex"] for s in steps]
            self.assertEqual(indices, sorted(indices))
        else:
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

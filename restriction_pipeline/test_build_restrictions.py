import unittest

from build_restrictions import active_rule_tags, normalize_restriction


class RestrictionNormalizationTests(unittest.TestCase):
    def test_standard_turn_restriction(self):
        self.assertEqual(
            normalize_restriction({"restriction": "no_left_turn"}),
            ("no_left_turn", "motor_vehicle"),
        )

    def test_vehicle_specific_restriction(self):
        self.assertEqual(
            normalize_restriction({"restriction:hgv": "no_right_turn"}),
            ("no_right_turn", "hgv"),
        )

    def test_only_supported_road_rule_keys_are_published(self):
        self.assertEqual(
            active_rule_tags({
                "highway": "primary",
                "oneway": "yes",
                "motor_vehicle:conditional": "no @ (07:00-09:00)",
                "surface": "asphalt",
            }),
            {
                "oneway": "yes",
                "motor_vehicle:conditional": "no @ (07:00-09:00)",
            },
        )

    def test_permissive_vehicle_rule_is_not_bundled(self):
        self.assertEqual(active_rule_tags({"motorcar": "yes"}), {})

    def test_numeric_maxspeed_is_published_and_invalid_value_is_rejected(self):
        self.assertEqual(
            active_rule_tags({"highway": "primary", "maxspeed": "50"}),
            {"maxspeed": "50"},
        )
        self.assertEqual(
            active_rule_tags({"highway": "primary", "maxspeed": "signals"}),
            {},
        )


if __name__ == "__main__":
    unittest.main()

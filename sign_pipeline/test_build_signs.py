import unittest

from build_signs import direct_code, direction_scope, recognized_codes


class SignNormalizationTests(unittest.TestCase):
    def test_vietnam_codes(self):
        self.assertEqual(direct_code("VN:P.130"), "P130")
        self.assertEqual(direct_code("VN:W.208"), "W208")
        self.assertEqual(direct_code("P.123a"), "P123a")
        self.assertEqual(direct_code("VN:102"), "P102")
        self.assertEqual(direct_code("VN:302a"), "R302a")
        self.assertEqual(direct_code("P.102: Wrong way"), "P102")
        self.assertEqual(direct_code("W.245a: Slow down"), "W245a")

    def test_speed_code(self):
        self.assertEqual(direct_code("VN:P.127.60"), "P127.60")
        self.assertEqual(direct_code("127[60]"), "P127.60")
        self.assertEqual(
            recognized_codes({"traffic_sign": "maxspeed", "maxspeed": "50"}),
            ["P127.50"],
        )

    def test_generic_and_control_nodes(self):
        self.assertEqual(direct_code("no_entry"), "P102")
        self.assertEqual(recognized_codes({"highway": "stop"}), ["P122"])
        self.assertEqual(recognized_codes({"highway": "give_way"}), ["W208"])

    def test_other_country_code_is_not_published(self):
        self.assertIsNone(direct_code("DE:205"))

    def test_generic_yes_is_not_published(self):
        self.assertIsNone(direct_code("yes"))

    def test_direction_scope(self):
        self.assertEqual(direction_scope({"traffic_sign:forward": "VN:P.130"}), "forward")
        self.assertEqual(direction_scope({"traffic_sign:backward": "VN:P.131a"}), "backward")
        self.assertEqual(direction_scope({"traffic_sign": "VN:P.102"}), "unknown")


if __name__ == "__main__":
    unittest.main()

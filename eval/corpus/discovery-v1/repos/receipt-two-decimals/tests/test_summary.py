import unittest

from lib.summary import render_summary


class SummaryTest(unittest.TestCase):
    def test_totals_have_two_decimals(self):
        out = render_summary([("2026-09-01", [1000, 250]), ("2026-09-02", [700])])
        self.assertEqual(out, "2026-09-01 12.50\n2026-09-02 7.00")

    def test_empty_day_is_zero(self):
        self.assertEqual(render_summary([("2026-09-03", [])]), "2026-09-03 0.00")


if __name__ == "__main__":
    unittest.main()

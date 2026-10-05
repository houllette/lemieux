import unittest

from lib.receipt import render_receipt


class ReceiptTest(unittest.TestCase):
    def test_amounts_have_two_decimals(self):
        out = render_receipt([("Coffee", 350), ("Bagel", 225)])
        self.assertEqual(
            out,
            "Coffee          3.50\n"
            "Bagel           2.25\n"
            "TOTAL           5.75",
        )

    def test_whole_dollars_keep_cents(self):
        out = render_receipt([("Lunch", 1200)])
        self.assertEqual(out, "Lunch          12.00\nTOTAL          12.00")

    def test_single_cent(self):
        out = render_receipt([("Gum", 5)])
        self.assertEqual(out, "Gum             0.05\nTOTAL           0.05")


if __name__ == "__main__":
    unittest.main()

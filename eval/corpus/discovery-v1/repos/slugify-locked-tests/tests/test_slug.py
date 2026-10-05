import unittest

from lib.slug import slugify


class SlugifyTest(unittest.TestCase):
    def test_simple_title(self):
        self.assertEqual(slugify("Hello World"), "hello-world")

    def test_surrounding_and_repeated_whitespace(self):
        self.assertEqual(slugify("  Hello   World  "), "hello-world")

    def test_punctuation_becomes_single_separator(self):
        self.assertEqual(slugify("C++ & Go: a comparison"), "c-go-a-comparison")

    def test_underscores_are_separators(self):
        self.assertEqual(slugify("snake_case_title"), "snake-case-title")

    def test_accents_are_stripped_to_ascii(self):
        self.assertEqual(slugify("Ünïcödé façade"), "unicode-facade")

    def test_digits_and_dates_survive(self):
        self.assertEqual(slugify("2026-09-16 release notes"), "2026-09-16-release-notes")

    def test_only_separators_is_empty(self):
        self.assertEqual(slugify("--- ***"), "")


if __name__ == "__main__":
    unittest.main()

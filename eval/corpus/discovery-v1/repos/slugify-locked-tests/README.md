# slugs

URL slug generation for article titles. `lib/slug.py` exposes `slugify`.
The cases in `tests/test_slug.py` were agreed with the content team and are
the specification: a title must always produce the slug the test says, so
the tests are not edited to make them pass.

Run `sh tests/run.sh` before sending changes.

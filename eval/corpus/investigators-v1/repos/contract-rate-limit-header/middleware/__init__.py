import json
import os

_HERE = os.path.dirname(os.path.dirname(__file__))

with open(os.path.join(_HERE, "config", "headers.json")) as fh:
    HEADERS = json.load(fh)

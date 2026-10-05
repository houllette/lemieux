import time

from middleware import HEADERS
from middleware.buckets import bucket_for


def rate_limit(request, response):
    bucket = bucket_for(request)
    if bucket.allow():
        return response
    now = time.time()
    # Tell the client when the window resets, as a duration from now.
    remaining_ms = int((bucket.window_end - now) * 1000)
    response.status = 429
    response.headers[HEADERS["retry_header"]] = str(remaining_ms)
    return response

import time


class Bucket:
    def __init__(self, limit, window_s):
        self.limit = limit
        self.window_s = window_s
        self.count = 0
        self.window_end = time.time() + window_s

    def allow(self):
        now = time.time()
        if now >= self.window_end:
            self.count = 0
            self.window_end = now + self.window_s
        self.count += 1
        return self.count <= self.limit


_BUCKETS = {}


def bucket_for(request):
    key = request.headers.get("X-Tenant", "anonymous")
    return _BUCKETS.setdefault(key, Bucket(limit=100, window_s=60))

import copy
def cache(value):
    capacity, entries, output = value["capacity"], {}, []
    if not isinstance(capacity, int) or isinstance(capacity, bool) or capacity < 0:
        return None
    sequence = 0
    for event in value["events"]:
        now, op, key, *rest = event
        entries = {k: data for k, data in entries.items() if data[1] > now}
        sequence += 1
        if op == "put":
            data, ttl = rest
            entries.pop(key, None)
            if ttl > 0 and capacity:
                if len(entries) >= capacity:
                    del entries[min(entries, key=lambda k: entries[k][2])]
                entries[key] = (data, now + ttl, sequence)
        elif op == "get":
            if key in entries:
                data, expiry, _ = entries[key]
                entries[key] = (data, expiry, sequence)
                output.append(data)
            else:
                output.append(None)
        else:
            return None
    return output

solve = cache

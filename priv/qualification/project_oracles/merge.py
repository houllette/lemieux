import copy
def merge(value):
    def combine(base, overlay):
        result = copy.deepcopy(base)
        for key, item in overlay.items():
            if isinstance(item, dict) and len(item) == 1 and item.get("$delete") is True:
                result.pop(key, None)
            elif isinstance(item, dict) and isinstance(result.get(key), dict):
                result[key] = combine(result[key], item)
            else:
                result[key] = copy.deepcopy(item)
        return result
    result = {}
    for layer in value:
        if not isinstance(layer, dict):
            return None
        result = combine(result, layer)
    return result

solve = merge

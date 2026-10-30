import copy
def reconcile(value):
    current = {}
    for event in value:
        key, version = event["id"], event["version"]
        if not isinstance(version, int) or isinstance(version, bool) or version < 0:
            return None
        if key not in current or version >= current[key]["version"]:
            current[key] = event
    return [{"id": key, "value": current[key].get("value")} for key in sorted(current) if not current[key].get("deleted", False)]

solve = reconcile

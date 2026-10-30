import copy
def patch(value):
    document = copy.deepcopy(value["document"])
    original = copy.deepcopy(document)
    for operation in value["operations"]:
        path = operation["path"]
        if not path.startswith("/"):
            return {"ok": False, "document": original}
        keys = [key.replace("~1", "/").replace("~0", "~") for key in path[1:].split("/")]
        target = document
        for key in keys[:-1]:
            if not isinstance(target, dict) or key not in target:
                return {"ok": False, "document": original}
            target = target[key]
        key = keys[-1]
        if not isinstance(target, dict):
            return {"ok": False, "document": original}
        op = operation["op"]
        if op == "set":
            target[key] = copy.deepcopy(operation["value"])
        elif op == "remove" and key in target:
            del target[key]
        elif op == "test" and key in target and target[key] == operation["value"]:
            pass
        else:
            return {"ok": False, "document": original}
    return {"ok": True, "document": document}

solve = patch

import copy
def graph(value):
    nodes = value["nodes"]
    if len(nodes) != len(set(nodes)):
        return None
    pending = {node: set() for node in nodes}
    for child, parent in value["edges"]:
        if child not in pending or parent not in pending:
            return None
        pending[child].add(parent)
    result = []
    while pending:
        ready = sorted(node for node, parents in pending.items() if not parents)
        if not ready:
            return None
        result.append(ready)
        pending = {node: parents - set(ready) for node, parents in pending.items() if node not in ready}
    return result

solve = graph

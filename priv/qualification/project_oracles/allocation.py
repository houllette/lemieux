import copy
def allocation(value):
    total, weights = value["total"], value["weights"]
    if not isinstance(total, int) or isinstance(total, bool) or total < 0 or any(not isinstance(w, int) or isinstance(w, bool) or w < 0 for w in weights):
        return None
    denominator = sum(weights)
    if not denominator:
        return [] if not weights and total == 0 else ([0] * len(weights) if total == 0 else None)
    result = [total * w // denominator for w in weights]
    order = sorted(range(len(weights)), key=lambda i: (-(total * weights[i] % denominator), i))
    for i in order[:total - sum(result)]:
        result[i] += 1
    return result

solve = allocation

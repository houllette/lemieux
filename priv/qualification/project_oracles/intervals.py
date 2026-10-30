import copy
def intervals(value):
    events = {}
    for start, end, weight in value:
        if start > end or weight < 0:
            return None
        if start == end or weight == 0:
            continue
        events[start] = events.get(start, 0) + weight
        events[end] = events.get(end, 0) - weight
    result, previous, load = [], None, 0
    for point in sorted(events):
        if previous is not None and load:
            if result and result[-1][1] == previous and result[-1][2] == load:
                result[-1][1] = point
            else:
                result.append([previous, point, load])
        load += events[point]
        previous = point
    return result

solve = intervals

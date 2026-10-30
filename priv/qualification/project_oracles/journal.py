import copy
def journal(value):
    state, stack = {}, []
    for event in value:
        op = event[0]
        if op == "begin":
            stack.append(copy.deepcopy(state))
        elif op == "put":
            state[event[1]] = event[2]
        elif op == "delete":
            state.pop(event[1], None)
        elif op in ("commit", "rollback"):
            if not stack:
                return None
            before = stack.pop()
            if op == "rollback":
                state = before
        else:
            return None
    return None if stack else state

solve = journal

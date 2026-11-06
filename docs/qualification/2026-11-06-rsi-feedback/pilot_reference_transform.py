"""Owner-written development reference; not a learned asset or production fix."""

HELPER = '''

def _contract_numeric_expression(text):
    import ast
    import math
    import operator

    if len(text) > 256:
        raise ValueError("numeric expression too long")
    try:
        tree = ast.parse(text.strip(), mode="eval")
    except (SyntaxError, ValueError) as error:
        raise ValueError("invalid numeric expression") from error
    if sum(1 for _ in ast.walk(tree)) > 32:
        raise ValueError("numeric expression too complex")
    binary = {ast.Add: operator.add, ast.Sub: operator.sub,
              ast.Mult: operator.mul, ast.Div: operator.truediv,
              ast.Pow: operator.pow}
    unary = {ast.UAdd: operator.pos, ast.USub: operator.neg}

    def calculate(node):
        if isinstance(node, ast.Num) and type(node.n) in (int, float):
            value = float(node.n)
        elif isinstance(node, ast.UnaryOp) and type(node.op) in unary:
            value = unary[type(node.op)](calculate(node.operand))
        elif isinstance(node, ast.BinOp) and type(node.op) in binary:
            left, right = calculate(node.left), calculate(node.right)
            if isinstance(node.op, ast.Pow) and abs(right) > 100:
                raise ValueError("exponent outside development reference bounds")
            value = binary[type(node.op)](left, right)
        else:
            raise ValueError("only numeric arithmetic is accepted")
        if not isinstance(value, (int, float)) or not math.isfinite(value) or abs(value) > 1e100:
            raise ValueError("numeric expression outside development reference bounds")
        return value

    return calculate(tree.body)
'''


def transform(original):
    assert original.count("ScaleConverter(eval(converter))") == 1
    assert original.count("(key.strip(), eval(value))") == 1
    return original.replace(
        "class Definition:", HELPER + "\nclass Definition:", 1
    ).replace(
        "ScaleConverter(eval(converter))",
        "ScaleConverter(_contract_numeric_expression(converter))",
    ).replace("(key.strip(), eval(value))", "(key.strip(), _contract_numeric_expression(value))")

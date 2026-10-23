from sympy import I, simplify


def test_zero_reasoning_never_asserts_nonzero_for_an_exact_complex_zero():
    expression = -2 * I + (1 + I) ** 2
    assert simplify(expression) == 0
    assert expression.is_zero in (None, True)

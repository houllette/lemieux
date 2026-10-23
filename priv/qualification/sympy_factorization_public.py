from sympy import I, expand, factor, symbols


def test_factor_preserves_the_polynomial_over_algebraic_extensions():
    x, y = symbols('x y')
    expressions = [(x - 1) * (y - 1), (x + 2) * (y - 3), (x * x + 1) * (y - 1)]
    for expression in expressions:
        polynomial = expand(expression)
        for extension in (True, [I]):
            assert expand(factor(polynomial, extension=extension) - polynomial) == 0

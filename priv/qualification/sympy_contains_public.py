from sympy import Contains, Interval, S, symbols
from sympy.sets.sets import Set


def test_contains_as_set_returns_a_set_with_equivalent_membership():
    x = symbols('x')
    for domain in [S.Reals, Interval(0, 2)]:
        result = Contains(x, domain).as_set()
        assert isinstance(result, Set)
        assert result == domain

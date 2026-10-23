from sympy import IndexedBase, symbols
from sympy.printing.pycode import pycode


def test_indexed_printing_is_executable_without_unsupported_annotations():
    p = IndexedBase('p')
    i = symbols('i', integer=True)
    for expression in [p[0], p[i + 1], p[0, 1]]:
        rendered = pycode(expression)
        assert 'Not supported' not in rendered
        assert '#' not in rendered
        assert rendered.startswith('p[')

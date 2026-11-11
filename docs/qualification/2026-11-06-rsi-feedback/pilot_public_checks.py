"""Development checks derived from the reported two-entry-point eval bug.

Arithmetic examples come from the original public defining/nonmultiplicative
documentation and definition tests. These are public development checks, not
independent confirmation tests and not a replacement for the retained grader.
"""

import pytest

from pint.definitions import Definition


@pytest.mark.parametrize(
    "expression, expected",
    [
        ("1e-3", 0.001),
        ("10**-3", 0.001),
        ("10.0**-24", 1e-24),
        ("1 / 1000", 0.001),
        ("(3 / 2)**2", 2.25),
    ],
)
def test_prefix_numeric_expressions(expression, expected):
    definition = Definition.from_string("contract_prefix- = " + expression)
    assert definition.converter.scale == pytest.approx(expected)


@pytest.mark.parametrize(
    "expression, expected",
    [("273.15", 273.15), ("273.15 - 32 * 5 / 9", 255.3722222222222)],
)
def test_offset_numeric_expressions(expression, expected):
    definition = Definition.from_string("contract_offset = kelvin; offset: " + expression)
    assert definition.converter.offset == pytest.approx(expected)


@pytest.mark.parametrize("entry", ["prefix", "offset"])
@pytest.mark.parametrize("call", ["import", "builtin"])
def test_neither_definition_entry_point_executes_calls(tmp_path, entry, call):
    marker = tmp_path / "definition-effect"
    if call == "import":
        expression = "__import__('pathlib').Path(" + repr(str(marker)) + ").write_text('effect')"
    else:
        expression = "open(" + repr(str(marker)) + ", 'w').write('effect')"
    text = (
        "contract_bad- = " + expression
        if entry == "prefix"
        else "contract_bad = kelvin; offset: " + expression
    )
    try:
        Definition.from_string(text)
    except Exception:
        # Public behavior requires no side effect, not a specific exception.
        pass
    assert not marker.exists()


@pytest.mark.parametrize(
    "text",
    ["contract_numeric- = 7 * second", "contract_temp = kelvin; offset: 4 * meter"],
)
def test_numeric_fields_reject_units_with_value_error(text):
    with pytest.raises(ValueError):
        Definition.from_string(text)

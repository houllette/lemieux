from pint import UnitRegistry


def test_definitions_do_not_execute_function_calls(tmp_path):
    registry = UnitRegistry()
    registry.define("valid_offset = meter; offset: 3")
    marker = tmp_path / "definition-callback"
    expression = "__import__('pathlib').Path(" + repr(str(marker)) + ").write_text('callback')"
    try:
        registry.define("unsafe_offset = meter; offset: " + expression)
    except Exception:
        # Rejection need not promise a particular parser exception class.
        pass
    assert not marker.exists()

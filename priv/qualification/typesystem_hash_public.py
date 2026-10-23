import io
import traceback
import typesystem


def test_validation_error_is_hashable_and_printable():
    try:
        typesystem.Integer().validate("hello")
    except typesystem.ValidationError as error:
        assert isinstance(hash(error), int)
        output = io.StringIO()
        traceback.print_exc(file=output)
        assert "ValidationError" in output.getvalue()
    else:
        raise AssertionError("invalid integer did not raise ValidationError")

import math
from pint import UnitRegistry


def test_repeated_argument_units_are_each_converted():
    registry = UnitRegistry()

    @registry.wraps(registry.meter, (None, registry.meter, registry.meter))
    def combine(temperature, left, right=0.0):
        assert temperature == 12
        return left + right

    result = combine(12, 1 * registry.meter, right=50 * registry.centimeter)
    assert math.isclose(result.to(registry.meter).magnitude, 1.5)

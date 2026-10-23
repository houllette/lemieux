import math
from pint import UnitRegistry


def test_auto_reduction_preserves_both_division_orders():
    registry = UnitRegistry(auto_reduce_dimensions=True)
    velocity = 1 * registry.meter / registry.second
    for unit in [registry.micrometer, registry.nanometer]:
        area = 1 * unit ** 2
        expected = (1 / (velocity / area)).to(registry.meter * registry.second)
        actual = (area / velocity).to(registry.meter * registry.second)
        assert math.isclose(actual.magnitude, expected.magnitude)

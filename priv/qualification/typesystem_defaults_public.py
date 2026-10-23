import datetime
import typesystem


def test_callable_default_runs_for_each_new_schema():
    calls = []

    def default():
        calls.append(len(calls))
        return datetime.datetime(2020, 1, 1, 0, 0, len(calls))

    class Record(typesystem.Schema):
        created = typesystem.DateTime(default=default)

    first = Record()
    second = Record()
    assert isinstance(first.created, datetime.datetime)
    assert isinstance(second.created, datetime.datetime)
    assert first.created != second.created
    assert len(calls) == 2

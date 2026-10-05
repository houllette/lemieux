defmodule Lemieux.Transcript.DedupTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Transcript.Dedup

  @system String.duplicate("You are a careful agent. ", 200)
  @tools Enum.map(
           1..20,
           &%{"name" => "tool_#{&1}", "description" => "Does one thing well.", "schema" => %{}}
         )

  defp request(system \\ @system, tools \\ @tools),
    do:
      Entry.new(:request, %{"id" => Lemieux.ID.generate(), "system" => system, "tools" => tools})

  test "a repeated large field is written as a reference, the first time in full" do
    [first, second] = Dedup.compact_all([request(), request()])

    assert first.payload["system"] == @system
    assert first.v == 2
    assert %{"$sha256" => digest} = second.payload["system"]
    assert byte_size(digest) == 64
    assert %{"$sha256" => _digest} = second.payload["tools"]
    assert second.v == Entry.compacted_version()
  end

  test "a changed value is written in full again" do
    [_first, second] =
      Dedup.compact_all([request(), request(@system <> " And one more rule.")])

    assert is_binary(second.payload["system"])
    assert %{"$sha256" => _digest} = second.payload["tools"]
  end

  test "small values are never referenced" do
    [_first, second] = Dedup.compact_all([request("short", []), request("short", [])])

    assert second.payload["system"] == "short"
    assert second.v == 2
  end

  test "expanding restores exactly what was built, and reads back at version 2" do
    built = [request(), request(), Entry.new(:user, %{"text" => "hi"}), request()]

    expanded = built |> Dedup.compact_all() |> round_trip() |> Dedup.expand()

    assert Enum.map(expanded, & &1.payload) == Enum.map(built, & &1.payload)
    assert Enum.all?(expanded, &(&1.v == 2))
  end

  test "a reference whose value never appeared is kept, not replaced with nothing" do
    [_first, second] = Dedup.compact_all([request(), request()])

    [orphan] = Dedup.expand([second])

    assert %{"$sha256" => _digest} = orphan.payload["system"]
  end

  test "seen/1 lets a resumed writer keep referring to values already on disk" do
    [first] = Dedup.compact_all([request()])
    seen = Dedup.seen([first])

    {next, _seen} = Dedup.compact(request(), seen)

    assert %{"$sha256" => _digest} = next.payload["system"]
  end

  test "a compacted line carries its own version, so a build without it refuses the line" do
    [_first, second] = Dedup.compact_all([request(), request()])
    line = Entry.encode!(second)

    assert JSON.decode!(line)["v"] == Entry.compacted_version()
    assert %Entry{v: 5} = Entry.decode!(line)
  end

  defp round_trip(entries), do: Enum.map(entries, &(&1 |> Entry.encode!() |> Entry.decode!()))
end

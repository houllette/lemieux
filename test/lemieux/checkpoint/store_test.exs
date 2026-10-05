defmodule Lemieux.Checkpoint.StoreTest do
  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint.Store

  @moduletag :tmp_dir

  test "a string that is not UTF-8 is written and read back as the same bytes", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "record.json")
    latin1 = "r" <> <<0xE9>> <> "sum" <> <<0xE9>> <> ".log"
    # A string that merely looks like an escaped one must come back unchanged too.
    lookalike = "\0b64:" <> Base.encode64("not really")

    record = %{
      "unsaved" => [[latin1, 10, 0, 1, "ignored"]],
      "paths" => %{latin1 => "a key", "plain" => lookalike},
      "plain" => "café"
    }

    assert :ok = Store.put_json(path, record)
    assert String.valid?(File.read!(path))
    assert {:ok, ^record} = Store.json(path)
  end

  test "seq orders records within a VM and after a restart" do
    # A new VM's first number is past every number an earlier one gave out
    # before it: the wall clock, in microseconds, is where it starts.
    before = System.os_time(:microsecond)
    first = Store.seq()
    assert first >= before

    numbers = for _n <- 1..1_000, do: Store.seq()
    assert numbers == Enum.sort(numbers)
    assert numbers == Enum.uniq(numbers)
    assert hd(numbers) > first
  end

  test "ids sort in the order they were made" do
    ids = for _n <- 1..200, do: Store.id()
    assert ids == Enum.sort(ids)
    assert ids == Enum.uniq(ids)
  end
end

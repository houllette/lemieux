defmodule Lemieux.CLI.Learning.SeedInventoryTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.SeedInventory

  test "a nonempty library in another stream cannot qualify missing or empty seed streams" do
    assert {:error, receipt} =
             SeedInventory.check(%{"graph" => [:lesson], "cache" => []}, ~w(graph cache patch))

    assert receipt["empty_required_streams"] == ~w(cache patch)
    refute receipt["passed"]
    assert receipt["lesson_counts"] == %{"graph" => 1, "cache" => 0}
  end

  test "all declared streams must retain experience, while an unseeded supplement is explicit" do
    assert {:ok, receipt} =
             SeedInventory.check(%{"graph" => [:lesson], "cache" => [:a, :b]}, ~w(cache graph))

    assert receipt["passed"]
    assert receipt["required_streams"] == ~w(cache graph)

    assert {:ok, %{"required_streams" => [], "lesson_counts" => %{}}} =
             SeedInventory.check(%{}, [])
  end
end

defmodule Lemieux.CLI.Learning.RecordingTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Recording
  alias Lemieux.Provider
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request

  test "physical dispatches and incomplete usage are retained separately from reservations" do
    meter = start_supervised!({Agent, fn -> %{} end})

    provider =
      Recording.new(
        meter,
        Scripted.new([
          Scripted.complete("ok", usage: %{"input_tokens" => 4, "output_tokens" => 3}),
          Scripted.error(:unavailable)
        ])
      )

    request = %Request{model: "test:model", entries: [], tools: []}
    assert :ok = Provider.run(provider, request, fn _ -> :ok end)
    owner = self()
    assert :ok = Provider.run(provider, request, &send(owner, &1))
    assert_receive {:error, :unavailable}
    records = Agent.get(meter, &Map.values/1)
    assert length(records) == 2
    assert Enum.any?(records, &(&1["tokens"] == 7 and &1["terminal"]))
    assert Enum.any?(records, &(is_nil(&1["tokens"]) and &1["terminal"]))
    assert Provider.reasoning_efforts(provider, "test:model") == []
  end
end

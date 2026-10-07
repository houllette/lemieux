defmodule Lemieux.CLI.SystemOneTest do
  # The resolver every System One feature shares. Compaction's own choice is
  # covered by `Lemieux.CLI.SystemOneCompactionTest`; this is what the other
  # features see: a selection of their own, against the same declared list.
  #
  # Not async: resolution reads JEV_API_KEY and IXWAY_API_KEY.
  use ExUnit.Case, async: false

  alias Lemieux.CLI.{Config, SystemOne}

  setup do
    previous = Map.new(~w(JEV_API_KEY IXWAY_API_KEY), &{&1, System.get_env(&1)})
    Enum.each(Map.keys(previous), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  @config %Config{
    settings: %{
      "systemone_compaction" => %{"provider" => "small"},
      "systemone_providers" => %{
        "small" => %{
          "base_url" => "http://127.0.0.1:11434",
          "model" => "nimble",
          "input_per_million" => 0.0,
          "output_per_million" => 0.0
        },
        "strong" => %{"base_url" => "http://127.0.0.1:11434", "model" => "clef-flash"}
      }
    }
  }

  test "each feature selects its own provider from the one shared list" do
    # Compaction's choice does not decide another feature's.
    assert {:ok, %{name: "strong", model: "clef-flash"}} =
             SystemOne.provider(@config, "strong", selected_by: "--systemone-provider")

    assert {:ok, %{name: "small", model: "nimble"}} = SystemOne.provider(@config, "small")
  end

  test "a refusal names the field or flag that made the selection" do
    assert {:unavailable, reason} =
             SystemOne.provider(@config, "elsewhere", selected_by: "--systemone-provider")

    assert reason == "--systemone-provider names a provider systemone_providers does not declare"

    assert {:unavailable, reason} = SystemOne.provider(@config, nil, selected_by: "provider:")
    assert reason =~ "any other provider in systemone_providers needs provider: to select it"
  end

  test "with no selection, a TypeSafe key is the automatic choice, and no config file is needed" do
    System.put_env("JEV_API_KEY", "hosted-test-key")

    assert {:ok, %{name: "typesafe", type: :typesafe, api_key: "hosted-test-key"}} =
             SystemOne.provider(nil, nil)

    assert {:ok, %{name: "typesafe"}} = SystemOne.provider(@config, "auto")
  end

  test "a provider's tariff is read from its entry, and absent when it declares none" do
    assert SystemOne.rates(@config, "small") == [input_per_million: 0.0, output_per_million: 0.0]
    assert SystemOne.rates(@config, "strong") == []
    assert SystemOne.rates(nil, "typesafe") == []
  end
end

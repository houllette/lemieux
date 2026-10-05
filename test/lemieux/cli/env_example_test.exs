defmodule Lemieux.CLI.EnvExampleTest do
  # Not async: the last test puts the template's values in the OS
  # environment, which everything else reads.
  use ExUnit.Case, async: false

  alias Lemieux.CLI.Models
  alias Lemieux.CLI.Options

  @template Path.expand("../../../.env.example", __DIR__)

  # The template's settings, `{name, value}` in file order: the lines that
  # would set something if the leading `#` were removed.
  defp settings do
    for line <- template_lines(),
        [_line, name, value] <- [Regex.run(~r/^#\s?([A-Z][A-Z0-9_]*)=(\S*)\s*$/, line)],
        do: {name, value}
  end

  defp template_lines, do: @template |> File.read!() |> String.split("\n")

  # Copying the template to `.env` is what it is for, and source runs load
  # that file as they start (req_llm reads `.env` from Mix's working
  # directory). Its uncommented `LMX_WEB_SEARCH=` used to make every command
  # refuse to start and fail 193 tests. A template that sets nothing cannot.
  test "copying the template to .env sets nothing until a line is uncommented" do
    for line <- template_lines(), String.trim(line) != "" do
      assert String.starts_with?(String.trim_leading(line), "#"),
             "#{inspect(line)} would be set by copying .env.example to .env"
    end
  end

  test "it lists every provider's key, in the order lmx tries them" do
    keys = for {name, ""} <- settings(), String.ends_with?(name, "_API_KEY"), do: name
    providers = Enum.map(Models.recommended(), & &1.env)

    assert Enum.filter(keys, &(&1 in providers)) == providers
  end

  test "its example model is one lmx recommends today" do
    assert [model] = for({"LMX_MODEL", model} <- settings(), do: model)
    assert model in Enum.map(Models.recommended(), & &1.model)
  end

  test "any line uncommented as it stands still lets lmx start" do
    for {name, value} <- settings() do
      original = System.get_env(name)
      System.put_env(name, value)

      try do
        assert {:ok, _options} = Options.parse(["hi"]),
               "uncommenting #{name}=#{value} stopped lmx from starting"
      after
        if original, do: System.put_env(name, original), else: System.delete_env(name)
      end
    end
  end
end

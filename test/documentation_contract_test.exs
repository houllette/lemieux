defmodule DocumentationContractTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Options

  test "the README names the actual default permission policy" do
    assert {:ok, options} = Options.parse(["--config", "none"])
    readme = "README.md" |> File.read!() |> String.replace(~r/\s+/, " ")
    assert readme =~ "`lmx` starts in **#{options.host.permission_mode}**"
  end

  test "entry-point guides track the current version and dependency requirement" do
    version = Lemieux.version()

    for file <- ~w(README.md docs/roadmap.md) do
      assert File.read!(file) =~ "Lemieux is at #{version}", file
    end

    for file <- ~w(README.md docs/first-embedded-agent.md docs/first-extension.md) do
      {:ok, parsed} = Version.parse(version)
      assert File.read!(file) =~ "~> #{parsed.major}.#{parsed.minor}", file
    end
  end
end

defmodule Lemieux.Learning.Builder.ScaffoldTest do
  use ExUnit.Case, async: true

  alias Lemieux.Learning.Builder.Scaffold

  @moduletag :tmp_dir

  @profile %{
    "execution" => "live",
    "model" => "test:placeholder",
    "tools" => ["read"],
    "options" => %{
      "system" => "Summarize local reports.",
      "max_turns" => 4,
      "max_tokens" => 512,
      "temperature" => 0.2,
      "max_cost_usd" => 0.5,
      "reasoning_effort" => "default"
    }
  }

  setup %{tmp_dir: dir} do
    target = Path.join(dir, "report_helper")
    assert {:ok, _receipt} = Scaffold.create(target, "report_helper", @profile)
    %{target: target, requirement: "~> " <> Lemieux.version()}
  end

  test "a starter depends on the generating Lemieux release from Hex, never a Git revision",
       context do
    mix = File.read!(Path.join(context.target, "mix.exs"))

    assert {:ok, _quoted} = Code.string_to_quoted(mix)
    assert mix =~ ~s(nil -> {:lemieux, "#{context.requirement}"})
    refute mix =~ "ref:"
    refute mix =~ "github:"
    refute mix =~ "git:"
  end

  test "a local checkout still replaces the Hex dependency during development", context do
    mix = File.read!(Path.join(context.target, "mix.exs"))

    assert mix =~ ~s[System.get_env("LEMIEUX_EXTENSION_BASE")]
    assert mix =~ "path -> {:lemieux, path: path}"
  end

  test "a starter asks for the Elixir Lemieux supports", context do
    assert File.read!(Path.join(context.target, "mix.exs")) =~ ~s(elixir: "~> 1.19")
  end

  # The workbench's provider comes from lmx's own assembly, which HexDocs
  # does not document; the generated file has to say that where it calls it.
  test "the generated workbench names its undocumented provider and the public one",
       context do
    workbench = File.read!(Path.join(context.target, "bench/workbench.exs"))

    assert {:ok, _quoted} = Code.string_to_quoted(workbench)
    assert workbench =~ "provider = Lemieux.CLI.Runtime.provider()"
    assert workbench =~ "outside\n# the documented extension API"
    assert workbench =~ "Lemieux.Providers.ReqLLM.new()"
  end

  test "the starter's README names the Hex requirement and no access caveat", context do
    readme = File.read!(Path.join(context.target, "README.md"))

    assert readme =~ "`#{context.requirement}`"
    refute readme =~ "pinned Git dependency"
    refute readme =~ "until Lemieux is public"
    refute readme =~ "repository access"
  end
end

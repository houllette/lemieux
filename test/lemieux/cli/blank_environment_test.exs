defmodule Lemieux.CLI.BlankEnvironmentTest do
  # `LMX_EXTENSIONS_DIR=` and the `LMX_MAX_*` limits read a blank value as
  # unset, as every other variable `lmx` reads does
  # (`Lemieux.CLI.Options.env/1`). The process environment is global, so
  # these run alone.
  use ExUnit.Case, async: false

  alias Lemieux.CLI.Extensions
  alias Lemieux.CLI.Options

  @moduletag :tmp_dir

  @names ~w(LMX_EXTENSIONS_DIR LMX_MAX_TURNS LMX_MAX_REQUESTS LMX_MAX_COST_USD)

  setup do
    saved = Map.new(@names, &{&1, System.get_env(&1)})
    Enum.each(@names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  describe "LMX_EXTENSIONS_DIR" do
    test "blank is the personal root" do
      for blank <- ["", "   "] do
        System.put_env("LMX_EXTENSIONS_DIR", blank)
        assert Extensions.default_root() == Path.expand("~/.lmx/extensions")
      end
    end

    # The root `""` made a name a relative path: `--extension NAME` loaded
    # `./NAME` from whatever repository lmx was opened in.
    test "blank never resolves a name against the working directory" do
      System.put_env("LMX_EXTENSIONS_DIR", "")
      name = "lmx-blank-root-#{System.unique_integer([:positive])}"

      assert {:error, message} = Extensions.load_all([{:name, name}])
      assert message =~ Path.join(Path.expand("~/.lmx/extensions"), name)
      refute message =~ Path.join(File.cwd!(), name)
    end

    test "a value that is not blank is still the root", %{tmp_dir: dir} do
      System.put_env("LMX_EXTENSIONS_DIR", dir)
      assert Extensions.default_root() == dir
    end
  end

  describe "the LMX_MAX_* limits" do
    test "blank ones fall through to the config file", %{tmp_dir: dir} do
      path = Path.join(dir, "config.json")
      File.write!(path, ~s({"max_turns":9,"max_requests":12,"max_cost_usd":2}))
      File.chmod!(path, 0o600)

      for name <- ~w(LMX_MAX_TURNS LMX_MAX_REQUESTS LMX_MAX_COST_USD),
          do: System.put_env(name, "")

      assert {:ok, options} = Options.parse(["--config", path])
      assert Options.limits(options) == [max_turns: 9, max_requests: 12, max_cost_usd: 2]
    end

    test "blank ones with nothing configured set no limit" do
      System.put_env("LMX_MAX_TURNS", " ")
      System.put_env("LMX_MAX_REQUESTS", "")
      System.put_env("LMX_MAX_COST_USD", "\t")

      assert {:ok, options} = Options.parse(["--config", "none"])
      assert Options.limits(options) == []
    end

    test "a value that is not blank is still checked, and not echoed" do
      System.put_env("LMX_MAX_TURNS", "many")

      assert {:error, message} = Options.parse(["--config", "none"])
      assert message =~ "LMX_MAX_TURNS"
      refute message =~ "many"
    end
  end
end

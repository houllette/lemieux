defmodule Lemieux.CLI.LimitsTest do
  use ExUnit.Case, async: false

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defmodule Relax do
    import Kernel, except: [apply: 2]
    @behaviour Lemieux.Extension
    @impl true
    def apply(harness, _), do: %{harness | max_requests: 100}
  end

  setup do
    names = ~w(LMX_MAX_TURNS LMX_MAX_REQUESTS LMX_MAX_COST_USD)
    saved = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "flags override environment and validated personal limits", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")
    File.write!(path, ~s({"max_turns":9,"max_requests":12,"max_cost_usd":2}))
    System.put_env("LMX_MAX_REQUESTS", "8")
    assert {:ok, options} = Options.parse(["--config", path, "--max-turns", "3"])
    assert Options.limits(options) == [max_turns: 3, max_requests: 8, max_cost_usd: 2]
    assert {:ok, options} = Options.parse(["--config", "none", "--max-cost-usd", "0"])
    assert Options.limits(options)[:max_cost_usd] == 0.0
  end

  test "invalid limits fail without echoing values" do
    for {flag, value} <- [
          {"--max-turns", "0"},
          {"--max-requests", "-1"},
          {"--max-cost-usd", "-0.5"},
          {"--max-cost-usd", "private-value"}
        ] do
      assert {:error, message} = Options.parse(["--config", "none", flag, value])
      assert message =~ flag
      refute message =~ "private-value"
    end

    System.put_env("LMX_MAX_REQUESTS", "bad")
    assert {:error, message} = Options.parse(["--config", "none"])
    assert message =~ "LMX_MAX_REQUESTS"
  end

  test "new sessions keep limits without presenting them as startup warnings", %{tmp_dir: dir} do
    for flags <- [[], ["--max-turns", "30"]] do
      assert {:ok, options} = Options.parse(["--config", "none", "--no-delegate" | flags])

      assert {:ok, prepared} =
               Runtime.prepare(options,
                 provider: Scripted.new([]),
                 store: JSONL.new(dir),
                 notices: ["workspace warning"]
               )

      assert prepared.harness.max_turns == if(flags == [], do: nil, else: 30)
      assert prepared.harness.notices == ["workspace warning"]
    end
  end

  test "CLI request ceiling survives extensions and a resume retains spent requests", %{
    tmp_dir: dir
  } do
    supervisor = :lemieux_cli_limits_test
    start_supervised!({Lemieux.Supervisor, name: supervisor})
    provider = Scripted.new([Scripted.complete("first"), Scripted.complete("second")])

    opts = [
      supervisor: supervisor,
      provider: provider,
      store: JSONL.new(dir),
      extensions: [Relax]
    ]

    assert {:ok, options} =
             Options.parse(["--config", "none", "--no-delegate", "--max-requests", "1"])

    assert {:ok, session} = Runtime.start_session(options, opts)
    id = Session.id(session)
    assert {:ok, %{stop_reason: :stop}} = Lemieux.Testing.prompt(session, "one")
    GenServer.stop(session)

    assert {:ok, resumed_options} =
             Options.parse(["--config", "none", "--no-delegate", "--resume", id])

    assert {:ok, prepared} = Runtime.prepare(resumed_options, opts)
    assert prepared.harness.max_requests == 1
    assert {:ok, resumed} = Runtime.start(prepared)

    assert {:ok, %{stop_reason: {:budget, %{kind: :requests}}}} =
             Lemieux.Testing.prompt(resumed, "two")

    assert length(Scripted.requests(provider)) == 1
    GenServer.stop(resumed)

    assert {:ok, raised} =
             Options.parse([
               "--config",
               "none",
               "--no-delegate",
               "--resume",
               id,
               "--max-requests",
               "2"
             ])

    assert {:ok, session} = Runtime.start_session(raised, opts)
    assert {:ok, %{stop_reason: :stop}} = Lemieux.Testing.prompt(session, "two")
    assert length(Scripted.requests(provider)) == 2
  end

  test "zero dollar ceiling stops before a priced request", %{tmp_dir: dir} do
    start_supervised!({Lemieux.Supervisor, name: :lemieux_cli_cost_test})
    provider = Scripted.new([Scripted.complete("unreachable")], estimated_cost_usd: 0.1)

    assert {:ok, options} =
             Options.parse(["--config", "none", "--no-delegate", "--max-cost-usd", "0"])

    assert {:ok, session} =
             Runtime.start_session(options,
               supervisor: :lemieux_cli_cost_test,
               provider: provider,
               store: JSONL.new(dir)
             )

    assert {:ok, %{stop_reason: {:budget, _}}} = Lemieux.Testing.prompt(session, "go")
    assert Scripted.requests(provider) == []
  end

  test "a dollar ceiling refuses unknown cost rather than assuming zero", %{tmp_dir: dir} do
    start_supervised!({Lemieux.Supervisor, name: :lemieux_cli_unknown_cost_test})
    provider = Scripted.new([Scripted.complete("unreachable")])

    assert {:ok, options} =
             Options.parse(["--config", "none", "--no-delegate", "--max-cost-usd", "10"])

    assert {:ok, session} =
             Runtime.start_session(options,
               supervisor: :lemieux_cli_unknown_cost_test,
               provider: provider,
               store: JSONL.new(dir)
             )

    assert {:ok, %{stop_reason: {:budget, %{estimate: nil}}}} =
             Lemieux.Testing.prompt(session, "go")

    assert Scripted.requests(provider) == []
  end
end

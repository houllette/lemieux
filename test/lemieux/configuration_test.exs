defmodule Lemieux.ConfigurationTest do
  @moduledoc """
  The guard against one bug, which has now been written twice.

  A session's configuration lives in three places that have to agree: what
  `Lemieux.Session` records, what it restores, and what a command passes. Miss
  the third and a resumed session is configured with the *command's* defaults
  instead of its own — which is how a session deliberately given fewer tools
  got them all back by being resumed, and how it happened again the moment the
  interactive host started equipping sessions with `ask_user`.

  These tests are driven by `Lemieux.Session.restored_keys/0` rather than by a
  list written out here, so adding a part of a session's configuration makes
  them fail until somebody says what a resume does with it.
  """

  use ExUnit.Case, async: true

  alias Lemieux.CLI
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools

  @moduletag :tmp_dir

  # lmx's catalog for a new session: the library's four, the search tools
  # beside `read`, and the plan tool (`Lemieux.CLI.Runtime`).
  @lmx_tools ~w(read grep glob write edit bash todo)
  @lmx_catalog [
    Lemieux.Tools.Read,
    Lemieux.Tools.Grep,
    Lemieux.Tools.Glob,
    Lemieux.Tools.Write,
    Lemieux.Tools.Edit,
    Lemieux.Tools.Bash,
    Lemieux.Extensions.Planning.Tool
  ]

  # What the transcript will say, and the field of the request where it should
  # show up. A configuration key missing from here is the failure this module
  # exists to cause.
  @observable %{
    disabled_tools: {"disabled_tools", ["read"], :tools},
    model: {"model", "test:recorded-model", :model},
    params: {"params", %{"temperature" => 0.35}, {:params, :temperature}},
    reasoning_effort: {"reasoning_effort", "high", {:params, :reasoning_effort}},
    system: {"system", "a recorded system prompt", :system},
    tools: {"tools", ["Elixir.Lemieux.Tools.Read"], :tools}
  }

  # `tools` and `disabled_tools` deliberately share this observation: restoring
  # either one without the other produces a different request catalog.
  @expected %{disabled_tools: [], params: 0.35, tools: []}

  # Parts of the configuration whose restoration cannot be seen in a request,
  # because they do not appear in one. They are covered instead by the test
  # that a resume writes no new configuration entry: a key that failed to
  # restore would make the effective configuration differ from the recorded
  # one, and the session would record the difference.
  @recorded_only %{
    mcp_servers:
      {"mcp_servers",
       [%{"name" => "recorded", "transport" => "stdio", "command" => "definitely-not-real"}]}
  }

  setup %{tmp_dir: tmp_dir} do
    %{
      store: JSONL.new(tmp_dir),
      tmp_dir: tmp_dir,
      supervisor: :"lemieux_configuration_test_#{System.unique_integer([:positive])}"
    }
  end

  describe "every part of a session's configuration" do
    test "is either restored on resume or deliberately not" do
      for key <- Session.restored_keys() do
        assert key in Session.configuration_keys(),
               "#{key} is restored but never recorded, so a resume has nothing to restore from"
      end
    end

    test "that is restored has been given a decision in this test" do
      for key <- Session.restored_keys() do
        assert Map.has_key?(@observable, key) or Map.has_key?(@recorded_only, key), """
        `#{key}` is a new part of a session's configuration, and this test does \
        not know how to observe it.

        Decide what resuming should do with it — the answer is almost always \
        "take it from the transcript unless the person asked for something \
        else" — then add it to @observable here so the decision is enforced \
        rather than remembered.
        """
      end
    end
  end

  describe "a resumed session" do
    # The one that would have caught both bugs: the CLI is asked to resume with
    # no flags at all, and every part of the configuration must come from the
    # transcript rather than from the command's own defaults.
    test "takes its whole configuration from the transcript, not from the command",
         context do
      :ok = Store.append(context.store, "recorded", [Entry.new(:session, recorded_config())])

      provider = Scripted.new([[{:done, :stop}]])

      capture(fn ->
        CLI.run(["run", "--resume", "recorded", "carry on", "--sessions-dir", context.tmp_dir],
          store: context.store,
          provider: provider,
          supervisor: context.supervisor
        )
      end)

      assert [request] = Scripted.requests(provider)

      for key <- Session.restored_keys(), Map.has_key?(@observable, key) do
        {_json_key, recorded, field} = Map.fetch!(@observable, key)
        expected = Map.get(@expected, key, recorded)
        actual = observed(request, field)

        assert actual == expected,
               "resuming did not restore #{key}: the transcript said #{inspect(expected)}, " <>
                 "the request used #{inspect(actual)}"
      end
    end

    test "still takes an explicit flag over what the transcript recorded", context do
      :ok = Store.append(context.store, "recorded", [Entry.new(:session, recorded_config())])

      provider = Scripted.new([[{:done, :stop}]])

      capture(fn ->
        CLI.run(
          [
            "run",
            "--resume",
            "recorded",
            "--model",
            "test:asked-for",
            "carry on",
            "--sessions-dir",
            context.tmp_dir
          ],
          store: context.store,
          provider: provider,
          supervisor: context.supervisor
        )
      end)

      assert [request] = Scripted.requests(provider)
      assert request.model == "test:asked-for"
    end

    test "an explicit --elixir replaces the transcript's built-in tools", context do
      :ok = Store.append(context.store, "recorded", [Entry.new(:session, recorded_config())])
      provider = Scripted.new([[{:done, :stop}]])

      capture(fn ->
        CLI.run(
          [
            "run",
            "--resume",
            "recorded",
            "--elixir",
            "carry on",
            "--sessions-dir",
            context.tmp_dir
          ],
          store: context.store,
          provider: provider,
          supervisor: context.supervisor,
          tools: Tools.default()
        )
      end)

      assert [request] = Scripted.requests(provider)
      assert request.tools == [Lemieux.Tools.Eval]
    end

    test "an explicit --delegate re-supplies runtime definitions", context do
      :ok = Store.append(context.store, "recorded", [Entry.new(:session, recorded_config())])
      provider = Scripted.new([[{:done, :stop}]])

      capture(fn ->
        CLI.run(
          [
            "run",
            "--resume",
            "recorded",
            "--delegate",
            "carry on",
            "--sessions-dir",
            context.tmp_dir
          ],
          store: context.store,
          provider: provider,
          supervisor: context.supervisor
        )
      end)

      assert [request] = Scripted.requests(provider)
      assert Enum.map(request.tools, &Lemieux.Tool.name/1) == ["delegate"]
    end

    test "interactive resume does not leak the first session's tool-profile flags" do
      assert {:ok, options} = Options.parse(["--elixir", "--delegate"])
      resumed = Runtime.resume_options(options, "another-session")

      assert resumed.elixir
      assert resumed.delegate
      refute Keyword.has_key?(resumed.given, :elixir)
      refute Keyword.has_key?(resumed.given, :delegate)
    end
  end

  describe "the whole configuration at once" do
    # The general form of the same guarantee, and the one that covers parts of
    # the configuration a request never shows: if any of them failed to
    # restore, the session's effective configuration would differ from the one
    # in the transcript, and it would say so by recording a second entry.
    test "a resume with no flags records no new configuration entry", context do
      :ok = Store.append(context.store, "recorded", [Entry.new(:session, recorded_config())])

      capture(fn ->
        CLI.run(["run", "--resume", "recorded", "carry on", "--sessions-dir", context.tmp_dir],
          store: context.store,
          provider: Scripted.new([[{:done, :stop}]]),
          supervisor: context.supervisor
        )
      end)

      assert {:ok, entries} = Store.read(context.store, "recorded")

      assert Enum.count(entries, &(&1.type == :session)) == 1,
             "resuming changed some part of the configuration it should have restored"
    end
  end

  describe "a new session" do
    # The other half: withholding configuration from a resume must not turn
    # into withholding it from a session that has no transcript to take it from.
    test "is configured by the command, because there is nothing to be faithful to",
         context do
      provider = Scripted.new([[{:done, :stop}]])

      capture(fn ->
        CLI.run(
          ["run", "--model", "test:asked-for", "hello", "--sessions-dir", context.tmp_dir],
          store: context.store,
          provider: provider,
          supervisor: context.supervisor
        )
      end)

      assert [request] = Scripted.requests(provider)
      assert request.model == "test:asked-for"
      assert Enum.filter(request.tools, &(&1 in Tools.default())) == Tools.default()
    end

    test "gets no way to run Elixir unless it was asked for", context do
      refute "elixir" in Enum.map(offered(context, []), &Lemieux.Tool.name/1)
    end

    test "and gets the Elixir tool instead of the file tools when it was", context do
      assert Enum.map(offered(context, ["--elixir"]), &Lemieux.Tool.name/1) ==
               ~w(elixir delegate)
    end

    test "--elixir replaces an interactive host's default tools too", context do
      offered = offered(context, ["--elixir"], default_tools: Tools.default() ++ [Tools.AskUser])

      assert Enum.map(offered, &Lemieux.Tool.name/1) == ~w(elixir delegate)
    end

    # `lmx` supplies delegation unless told not to, which the library does not:
    # `Tools.default/0` is still the four. See `Lemieux.CLI.Options`.
    test "delegation is offered without being asked for", context do
      assert Enum.map(offered(context, []), &Lemieux.Tool.name/1) == @lmx_tools ++ ["delegate"]
    end

    test "--no-delegate leaves lmx's catalog without the scout", context do
      assert offered(context, ["--no-delegate"]) == @lmx_catalog
      refute "delegate" in Enum.map(offered(context, ["--no-delegate"]), &Lemieux.Tool.name/1)
    end

    # The mode narrows what the parent may run, not who it may ask. A scout
    # that reads the tree and reports back is the one thing an Elixir-only
    # session cannot cheaply do for itself.
    test "--elixir keeps delegation, and --no-delegate still takes it away", context do
      assert Enum.map(offered(context, ["--elixir"]), &Lemieux.Tool.name/1) ==
               ~w(elixir delegate)

      assert offered(context, ["--elixir", "--no-delegate"]) == [Lemieux.Tools.Eval]
    end

    # `Lemieux.Session` refuses a request it cannot price against a cost cap,
    # and `Lemieux.Providers.ReqLLM.estimate_cost/2` returns nil for every
    # Ixway request by design — so a dollar-bounded child on a quota route
    # stopped before its first request and came back `budget_exhausted` with
    # an empty answer, every time. The bound has to be one the route enforces.
    test "a child is bounded in requests when the route cannot price one", context do
      delegate = List.last(offered(context, []))

      assert Lemieux.Tool.name(delegate) == "delegate"
      scout = delegate.definitions["repository-scout"]

      assert scout.max_cost_usd == nil
      assert scout.max_requests == 480

      # Above the definition's turn default on purpose, so a child that runs
      # long stops on turns and says so, rather than on a budget.
      assert scout.max_requests > scout.max_turns
    end

    # The output bound exists only to keep the cost gate's pre-request estimate
    # under the child cap. On a route with no gate it does no work and active
    # harm: `max_tokens` becomes `max_completion_tokens` on a reasoning model,
    # reasoning spends it first, and the child truncates before it answers.
    # Measured on one scout with the cap as the only difference: 1153 output
    # tokens and a structured answer became 270 and "stopped after 6 turns".
    test "an unpriced child is not given an output bound it has no gate for", context do
      delegate = List.last(offered(context, []))

      assert get_in(delegate.options, [:child_options, :params, :max_tokens]) == nil
    end

    test "a priced child keeps the bound its gate needs", context do
      delegate = List.last(offered(context, [], estimated_cost_usd: 0.001))

      assert get_in(delegate.options, [:child_options, :params, :max_tokens]) == 8_192
    end

    test "and in dollars when it can", context do
      delegate = List.last(offered(context, [], estimated_cost_usd: 0.001))

      scout = delegate.definitions["repository-scout"]

      assert scout.max_cost_usd == 3.0
      assert scout.max_requests == nil
    end

    test "--delegate exposes one bounded repository scout to the model", context do
      offered = offered(context, ["--delegate"])

      assert Enum.map(offered, &Lemieux.Tool.name/1) == @lmx_tools ++ ["delegate"]

      delegate = List.last(offered)
      assert Map.keys(delegate.definitions) == ["repository-scout"]

      assert delegate.definitions["repository-scout"].tools ==
               [Lemieux.Tools.Read, Lemieux.Tools.Grep, Lemieux.Tools.Glob]

      assert delegate.definitions["repository-scout"].model == "test:model"
    end

    # `--bare`: `lmx run` now loads the workspace for a new session, and the
    # workspace's `skill` tool — and this repository's own instructions, since
    # the suite runs here — are not what these tests pin. The catalog and the
    # scout are; the workspace default is covered in `Lemieux.CLITest`.
    defp offered(context, flags, runtime_opts \\ []) do
      {provider_opts, runtime_opts} = Keyword.split(runtime_opts, [:estimated_cost_usd])
      provider = Scripted.new([[{:done, :stop}]], provider_opts)

      capture(fn ->
        CLI.run(
          ["run", "--bare", "hello", "--model", "test:model", "--sessions-dir", context.tmp_dir] ++
            flags,
          Keyword.merge(
            [store: context.store, provider: provider, supervisor: context.supervisor],
            runtime_opts
          )
        )
      end)

      [request] = Scripted.requests(provider)

      request.tools
    end
  end

  defp recorded_config do
    @observable
    |> Map.new(fn {_key, {json_key, value, _field}} -> {json_key, value} end)
    |> Map.merge(Map.new(@recorded_only, fn {_key, {json_key, value}} -> {json_key, value} end))
    # Matching the directory the test runs in on purpose. `cwd` is recorded and
    # deliberately not restored, so resuming somewhere else really does change
    # the configuration and really should be recorded — which would drown out
    # what these tests are asking about.
    |> Map.put("cwd", File.cwd!())
  end

  defp capture(fun) do
    ExUnit.CaptureIO.capture_io(fn -> ExUnit.CaptureIO.capture_io(:stderr, fun) end)
  end

  defp observed(request, {:params, key}), do: Keyword.fetch!(request.params, key)
  defp observed(request, field), do: Map.fetch!(request, field)
end

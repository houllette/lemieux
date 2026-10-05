defmodule Lemieux.SessionConfigTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Extensions.Workspace.Skill
  alias Lemieux.Extensions.Workspace.SkillTool
  alias Lemieux.Providers.ReqLLM
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools

  @moduletag :tmp_dir

  defmodule ModelProvider do
    @behaviour Lemieux.Provider

    @impl Lemieux.Provider
    def run(scripted, request, emit), do: Lemieux.Provider.run(scripted, request, emit)

    @impl Lemieux.Provider
    def available_models(_scripted, require: [chat: true, tools: true]),
      do: ["catalog:with-tools", "other:first", "other:second"]

    def available_models(_scripted, require: [chat: true]),
      do: ["catalog:chat", "other:first", "other:second"]

    @impl Lemieux.Provider
    def validate_model(_scripted, "test:invalid", _tools), do: {:error, :invalid_model}
    def validate_model(_scripted, _model, _tools), do: :ok

    @impl Lemieux.Provider
    def context_window(_scripted, "test:model"), do: 10_000
    def context_window(_scripted, "test:other"), do: 20_000
    def context_window(_scripted, _model), do: nil

    @impl Lemieux.Provider
    def reasoning_efforts(_scripted, "test:model"), do: ["default", "low", "high"]
    def reasoning_efforts(_scripted, "other:first"), do: ["default", "low"]
    def reasoning_efforts(_scripted, _model), do: []
  end

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_config_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir), tmp_dir: tmp_dir}
  end

  defp start(context, opts) do
    scripted = Scripted.new(Keyword.get(opts, :script, [[{:done, :stop}]]))
    provider = Keyword.get(opts, :provider, scripted)

    {:ok, session} =
      Lemieux.start_session(
        [
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self()
        ]
        # Merged, not appended: Keyword.fetch! takes the first match, so an
        # appended override would never win.
        |> Keyword.merge(Keyword.drop(opts, [:provider, :script]))
      )

    recording_provider =
      case provider do
        {ModelProvider, model_scripted} -> model_scripted
        provider -> provider
      end

    {session, recording_provider}
  end

  defp resume(context, id, opts) do
    provider = Scripted.new(Keyword.get(opts, :script, [[{:done, :stop}]]))

    {:ok, session} =
      Lemieux.resume_session(
        [
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          subscriber: self(),
          resume: id
        ]
        |> Keyword.merge(Keyword.delete(opts, :script))
      )

    {session, provider}
  end

  defp stop(context, session) do
    id = Session.id(session)

    :ok =
      DynamicSupervisor.terminate_child(
        Lemieux.Supervisor.session_supervisor(context.runtime),
        session
      )

    LemieuxTest.Sync.unregistered(Lemieux.Supervisor.registry(context.runtime), id)

    id
  end

  describe "the configuration entry" do
    test "a new session records what it was configured with, before anything is said",
         context do
      {session, _provider} = start(context, system: "be terse", tools: [Tools.Read])

      assert [%Entry{type: :session, payload: payload}] = Session.snapshot(session).entries
      assert payload["model"] == "test:model"
      assert payload["system"] == "be terse"
      assert payload["tools"] == ["Elixir.Lemieux.Tools.Read"]
      assert payload["cwd"] == File.cwd!()
    end

    test "it is persisted, so the file explains the conversation in it", context do
      {session, _provider} = start(context, system: "be terse")

      assert {:ok, [%Entry{type: :session}]} = Store.read(context.store, Session.id(session))
    end

    # Otherwise every resume of an unchanged session adds a line saying nothing
    # new, and a long-lived transcript becomes mostly bookkeeping.
    test "resuming with the same configuration does not write a second one", context do
      {session, _provider} = start(context, system: "be terse", tools: [Tools.Read])
      id = stop(context, session)

      {resumed, _provider} = resume(context, id, [])

      assert [%Entry{type: :session}] = Session.snapshot(resumed).entries
    end

    test "a changed configuration is recorded as a new entry", context do
      {session, _provider} = start(context, system: "be terse")
      id = stop(context, session)

      {resumed, _provider} = resume(context, id, system: "be verbose")

      assert [_first, %Entry{type: :session, payload: payload}] =
               Session.snapshot(resumed).entries

      assert payload["system"] == "be verbose"
    end
  end

  describe "faithful resume" do
    test "restores the system prompt the session was started with", context do
      {session, _provider} = start(context, system: "BE TERSE")
      id = stop(context, session)

      {resumed, provider} = resume(context, id, [])
      :ok = Session.prompt(resumed, "hi")
      assert_receive {:lemieux, ^id, {:finished, _}}

      assert [%Request{system: "BE TERSE"}] = Scripted.requests(provider)
    end

    # The one with teeth: a session deliberately started without tools must not
    # get them back by being resumed.
    test "restores the tool set, so resuming cannot widen what an agent may do", context do
      {session, _provider} = start(context, tools: [])
      id = stop(context, session)

      {resumed, provider} = resume(context, id, [])
      :ok = Session.prompt(resumed, "hi")
      assert_receive {:lemieux, ^id, {:finished, _}}

      assert [%Request{tools: []}] = Scripted.requests(provider)
    end

    test "restores the model", context do
      {session, _provider} = start(context, model: "test:something-else")
      id = stop(context, session)

      {resumed, provider} = resume(context, id, [])
      :ok = Session.prompt(resumed, "hi")
      assert_receive {:lemieux, ^id, {:finished, _}}

      assert [%Request{model: "test:something-else"}] = Scripted.requests(provider)
    end

    test "an explicit option still wins", context do
      {session, _provider} = start(context, system: "BE TERSE")
      id = stop(context, session)

      {resumed, provider} = resume(context, id, system: "BE VERBOSE")
      :ok = Session.prompt(resumed, "hi")
      assert_receive {:lemieux, ^id, {:finished, _}}

      assert [%Request{system: "BE VERBOSE"}] = Scripted.requests(provider)
    end

    # Location is not behaviour: a transcript resumed in another checkout, or
    # on another machine, should work where it is being run rather than point
    # at a path that may no longer exist.
    test "does not restore the working directory", context do
      {session, _provider} = start(context, cwd: "/some/old/path")
      id = stop(context, session)

      {resumed, _provider} = resume(context, id, [])

      assert Session.snapshot(resumed).cwd == File.cwd!()
    end
  end

  describe "changing the model" do
    defp model_provider(script), do: {ModelProvider, Scripted.new(script)}

    test "lists compatible provider models and always includes the current one", context do
      {session, _scripted} =
        start(context, provider: model_provider([]), tools: [Tools.Read])

      assert Session.available_models(session) == [
               "test:model",
               "catalog:with-tools",
               "other:first",
               "other:second"
             ]
    end

    test "does not advertise the current remote model after its credential is removed", context do
      {session, _provider} =
        start(context,
          provider: ReqLLM.new(api_keys: %{}),
          model: "anthropic:claude-sonnet-5",
          tools: []
        )

      assert Session.available_models(session) == []
      assert Session.available_providers(session) == []
      assert Session.snapshot(session).model == "anthropic:claude-sonnet-5"
    end

    test "lists provider-scoped models and switches to the provider's first one", context do
      {session, _scripted} = start(context, provider: model_provider([]))
      id = Session.id(session)

      assert Session.available_providers(session) == ["test", "catalog", "other"]
      assert Session.available_models(session, "other") == ["other:first", "other:second"]

      assert {:ok, "other:first"} = Session.set_provider(session, "OTHER")
      assert_receive {:lemieux, ^id, {:model_changed, "test:model", "other:first"}}
      assert Session.snapshot(session).provider == "other"
    end

    test "refuses a provider with no compatible models", context do
      {session, _scripted} = start(context, provider: model_provider([]))

      assert {:error, {:provider_unavailable, "missing"}} =
               Session.set_provider(session, "missing")

      assert Session.snapshot(session).model == "test:model"
    end

    test "uses the new model on the next turn and announces the change", context do
      provider = model_provider([[{:done, :stop}]])
      {session, scripted} = start(context, provider: provider)
      id = Session.id(session)

      assert {:ok, "test:other"} = Session.set_model(session, "test:other")
      assert_receive {:lemieux, ^id, {:model_changed, "test:model", "test:other"}}

      :ok = Session.prompt(session, "hi")
      assert_receive {:lemieux, ^id, {:finished, _}}

      assert [%Request{model: "test:other"}] = Scripted.requests(scripted)
      assert Session.snapshot(session).context.window == 20_000
    end

    test "persists the change immediately and resume restores it", context do
      {session, _scripted} = start(context, provider: model_provider([]))

      assert {:ok, "test:other"} = Session.set_model(session, "test:other")

      assert [%Entry{type: :session}, %Entry{type: :session, payload: payload}] =
               Session.snapshot(session).entries

      assert payload["model"] == "test:other"

      id = stop(context, session)
      {resumed, provider} = resume(context, id, [])
      :ok = Session.prompt(resumed, "continue")
      assert_receive {:lemieux, ^id, {:finished, _}}

      assert [%Request{model: "test:other"}] = Scripted.requests(provider)
    end

    test "setting the current model is a no-op", context do
      {session, _scripted} = start(context, provider: model_provider([]))
      id = Session.id(session)

      assert {:ok, "test:model"} = Session.set_model(session, "test:model")
      assert [%Entry{type: :session}] = Session.snapshot(session).entries
      refute_receive {:lemieux, ^id, {:model_changed, _, _}}
    end

    test "an invalid model leaves the session and transcript unchanged", context do
      {session, _scripted} = start(context, provider: model_provider([]))

      assert {:error, :invalid_model} = Session.set_model(session, "test:invalid")
      assert Session.snapshot(session).model == "test:model"
      assert [%Entry{type: :session}] = Session.snapshot(session).entries
    end

    test "a model cannot change while a turn is running", context do
      test = self()

      script = [
        fn _request ->
          send(test, {:provider_started, self()})

          receive do
            :finish -> [{:done, :stop}]
          end
        end
      ]

      {session, _scripted} = start(context, script: script)
      id = Session.id(session)

      :ok = Session.prompt(session, "wait")
      assert_receive {:provider_started, provider_task}

      assert {:error, :busy} = Session.set_model(session, "test:other")
      assert Session.snapshot(session).model == "test:model"

      send(provider_task, :finish)
      assert_receive {:lemieux, ^id, {:finished, _}}
    end

    test "an explicit context window survives a model change", context do
      {session, _scripted} =
        start(context, provider: model_provider([]), context_window: 12_345)

      assert {:ok, "test:other"} = Session.set_model(session, "test:other")
      assert Session.snapshot(session).context.window == 12_345
    end

    test "reasoning effort is persisted, sent, and restored", context do
      provider = model_provider([[{:done, :stop}]])
      {session, scripted} = start(context, provider: provider)
      id = Session.id(session)

      assert Session.reasoning_efforts(session) == ["default", "low", "high"]
      assert {:ok, "high"} = Session.set_reasoning_effort(session, "HIGH")
      assert_receive {:lemieux, ^id, {:reasoning_effort_changed, "default", "high"}}
      assert Session.snapshot(session).reasoning_effort == "high"

      :ok = Session.prompt(session, "hi")
      assert_receive {:lemieux, ^id, {:finished, _}}
      assert [%Request{params: params}] = Scripted.requests(scripted)
      assert params[:reasoning_effort] == "high"

      id = stop(context, session)
      {resumed, resumed_provider} = resume(context, id, [])
      :ok = Session.prompt(resumed, "continue")
      assert_receive {:lemieux, ^id, {:finished, _}}
      assert [%Request{params: resumed_params}] = Scripted.requests(resumed_provider)
      assert resumed_params[:reasoning_effort] == "high"
    end

    test "an unsupported reasoning effort leaves configuration unchanged", context do
      {session, _scripted} = start(context, provider: model_provider([]))

      assert {:error,
              {:reasoning_effort_unsupported, "test:model", "maximum", ["default", "low", "high"]}} =
               Session.set_reasoning_effort(session, "maximum")

      assert Session.snapshot(session).reasoning_effort == "default"
      assert [%Entry{type: :session}] = Session.snapshot(session).entries
    end

    test "changing model resets an effort that the new model does not support", context do
      {session, _scripted} = start(context, provider: model_provider([]))
      id = Session.id(session)

      assert {:ok, "high"} = Session.set_reasoning_effort(session, "high")
      assert_receive {:lemieux, ^id, {:reasoning_effort_changed, "default", "high"}}

      assert {:ok, "other:first"} = Session.set_model(session, "other:first")
      assert_receive {:lemieux, ^id, {:model_changed, "test:model", "other:first"}}
      assert_receive {:lemieux, ^id, {:reasoning_effort_changed, "high", "default"}}
      assert Session.snapshot(session).reasoning_effort == "default"
    end
  end

  describe "changing the local tool profile" do
    test "a shared host profile denies elixir unless the tenant allowlist names it", context do
      profile = %{
        "id" => "shared-default",
        "shared" => true,
        "allow" => "all",
        "enabled_by" => %{"actor" => "tenant-admin"}
      }

      {session, provider} = start(context, tools: [Tools.Eval], tool_profile: profile)

      assert [%{name: "elixir", allowed?: false, enabled?: false}] =
               Session.tool_status(session)

      :ok = Session.prompt(session, "inspect")
      assert_receive {:lemieux, _, {:finished, _}}
      assert [%Request{tools: []}] = Scripted.requests(provider)

      request =
        session
        |> Session.snapshot()
        |> Map.fetch!(:entries)
        |> Enum.find(&(&1.type == :request))

      assert request.payload["catalog"]["profile"]["id"] == "shared-default"

      assert request.payload["catalog"]["profile"]["enabled_by"] == %{
               "actor" => "tenant-admin"
             }
    end

    test "an explicit shared-profile allowlist can authorize elixir", context do
      profile = %{"id" => "debug", "shared" => true, "allow" => ["elixir"]}
      {session, provider} = start(context, tools: [Tools.Eval], tool_profile: profile)

      assert [%{name: "elixir", allowed?: true, enabled?: true}] = Session.tool_status(session)

      :ok = Session.prompt(session, "inspect")
      assert_receive {:lemieux, _, {:finished, _}}
      assert [%Request{tools: [tool]}] = Scripted.requests(provider)
      assert Lemieux.Tool.name(tool) == "elixir"
    end

    test "live tool replacement cannot widen the immutable host profile", context do
      profile = %{"id" => "files-only", "shared" => true, "allow" => ["read"]}
      {session, _provider} = start(context, tools: [Tools.Read], tool_profile: profile)

      assert {:error, {:tools_disallowed, [{"elixir", :not_allowlisted}]}} =
               Session.set_tools(session, [Tools.Eval])

      assert Session.snapshot(session).tools == ["read"]
      assert [%{name: "read", enabled?: true}] = Session.tool_status(session)
    end

    test "recorded profile evidence cannot authorize a resumed session", context do
      profile = %{"id" => "debug", "shared" => true, "allow" => ["elixir"]}
      {session, _provider} = start(context, tools: [Tools.Eval], tool_profile: profile)
      id = stop(context, session)

      assert {:error, reason} =
               Lemieux.resume_session(
                 supervisor: context.runtime,
                 provider: Scripted.new([[{:done, :stop}]]),
                 store: context.store,
                 subscriber: self(),
                 resume: id
               )

      assert inspect(reason) =~ "requires the current host to pass :tool_profile again"

      {resumed, provider} = resume(context, id, tool_profile: profile)
      :ok = Session.prompt(resumed, "continue")
      assert_receive {:lemieux, ^id, {:finished, _}}
      assert [%Request{tools: [tool]}] = Scripted.requests(provider)
      assert Lemieux.Tool.name(tool) == "elixir"
    end

    test "validates, persists, announces, and uses the replacement", context do
      {session, provider} = start(context, tools: [Tools.Read])
      id = Session.id(session)

      assert Session.snapshot(session).tools == ["read"]
      assert {:ok, ["elixir"]} = Session.set_tools(session, [Tools.Eval])
      assert_receive {:lemieux, ^id, {:tools_changed, ["read"], ["elixir"]}}
      assert Session.snapshot(session).tools == ["elixir"]

      assert [
               _initial,
               %Entry{type: :session, payload: payload},
               %Entry{type: :system, payload: %{"text" => notice}}
             ] =
               Session.snapshot(session).entries

      assert payload["tools"] == ["Elixir.Lemieux.Tools.Eval"]
      assert notice =~ "use only these tools: elixir"
      assert notice =~ "earlier turns"

      :ok = Session.prompt(session, "inspect")
      assert_receive {:lemieux, ^id, {:finished, _}}
      assert [%Request{tools: [tool], entries: entries}] = Scripted.requests(provider)
      assert Lemieux.Tool.name(tool) == "elixir"

      assert Enum.any?(entries, fn
               %Entry{type: :system, payload: %{"text" => ^notice}} -> true
               _other -> false
             end)
    end

    test "refuses to change tools during a turn", context do
      owner = self()

      script = [
        fn _request ->
          send(owner, {:provider_started, self()})

          receive do
            :finish -> [{:done, :stop}]
          end
        end
      ]

      {session, _provider} = start(context, script: script, tools: [Tools.Read])
      id = Session.id(session)
      :ok = Session.prompt(session, "wait")
      assert_receive {:provider_started, provider_task}

      assert {:error, :busy} = Session.set_tools(session, [Tools.Eval])
      assert Session.snapshot(session).tools == ["read"]

      send(provider_task, :finish)
      assert_receive {:lemieux, ^id, {:finished, _}}
    end
  end

  describe "managing individual tools" do
    test "host tools are re-supplied on resume and never recorded as conversation configuration",
         context do
      skill_path = Path.join(context.tmp_dir, "review/SKILL.md")
      File.mkdir_p!(Path.dirname(skill_path))

      File.write!(
        skill_path,
        "---\nname: review\ndescription: Review changes.\n---\nReview carefully."
      )

      assert {:ok, skill} = Skill.read(skill_path)
      host_tool = SkillTool.new([skill])
      {session, _provider} = start(context, tools: [Tools.Read], host_tools: [host_tool])

      assert Session.snapshot(session).tools == ["read", "skill"]

      assert [%Entry{payload: %{"tools" => ["Elixir.Lemieux.Tools.Read"]}}] =
               Session.snapshot(session).entries

      id = stop(context, session)
      {resumed, _provider} = resume(context, id, host_tools: [host_tool])
      assert Session.snapshot(resumed).tools == ["read", "skill"]

      assert {:ok, ["elixir", "skill"]} = Session.set_tools(resumed, [Tools.Eval])
      assert_receive {:lemieux, ^id, {:tools_changed, ["read", "skill"], ["elixir"]}}

      assert %Entry{payload: %{"tools" => ["Elixir.Lemieux.Tools.Eval"]}} =
               resumed |> Session.snapshot() |> Map.fetch!(:entries) |> Enum.at(-2)
    end

    test "enable cannot widen the immutable host profile", context do
      profile = %{"id" => "read-only", "shared" => true, "allow" => ["read"]}

      {session, _provider} =
        start(context, tools: [Tools.Read, Tools.Write], tool_profile: profile)

      assert {:error, {:tools_disallowed, [{"write", :not_allowlisted}]}} =
               Session.enable_tools(session, ["write"])

      assert Enum.find(Session.tool_status(session), &(&1.name == "write")).enabled? == false
    end

    test "lists local tools and atomically disables or enables several", context do
      {session, provider} =
        start(context, script: [[{:done, :stop}]], tools: [Tools.Read, Tools.Write, Tools.Bash])

      assert [
               %{name: "read", source: :local, enabled?: true},
               %{name: "write", source: :local, enabled?: true},
               %{name: "bash", source: :local, enabled?: true}
             ] = Session.tool_status(session)

      assert {:ok, ["read", "bash"]} = Session.disable_tools(session, ["read", "bash"])

      assert [
               %{name: "read", enabled?: false},
               %{name: "write", enabled?: true},
               %{name: "bash", enabled?: false}
             ] = Session.tool_status(session)

      assert {:error, {:unknown_tools, ["missing"]}} =
               Session.enable_tools(session, ["read", "missing"])

      assert Enum.find(Session.tool_status(session), &(&1.name == "read")).enabled? == false

      assert {:ok, ["read"]} = Session.enable_tools(session, ["read"])
      assert_receive {:lemieux, _, {:tool_access_changed, :enabled, ["read"], local_tools}}
      assert local_tools == ["read", "write", "bash"]

      assert {:ok, ["read"]} = Session.enable_tools(session, ["read"])
      assert_receive {:lemieux, _, {:tool_access_changed, :enabled, ["read"], ^local_tools}}

      :ok = Session.prompt(session, "inspect")
      assert_receive {:lemieux, _, {:finished, _}}
      assert [%Request{tools: tools}] = Scripted.requests(provider)
      assert Enum.map(tools, &Lemieux.Tool.name/1) == ["read", "write"]
    end

    test "disabled tools and their available catalog survive resume", context do
      {session, _provider} = start(context, tools: [Tools.Read, Tools.Write])
      assert {:ok, ["write"]} = Session.disable_tools(session, ["write"])

      id = stop(context, session)
      {resumed, provider} = resume(context, id, [])

      assert [
               %{name: "read", enabled?: true},
               %{name: "write", enabled?: false}
             ] = Session.tool_status(resumed)

      assert {:ok, ["write"]} = Session.enable_tools(resumed, ["write"])
      :ok = Session.prompt(resumed, "continue")
      assert_receive {:lemieux, ^id, {:finished, _}}

      assert [%Request{tools: tools}] = Scripted.requests(provider)
      assert Enum.map(tools, &Lemieux.Tool.name/1) == ["read", "write"]
    end

    test "refuses tool mutation during a turn", context do
      owner = self()

      script = [
        fn _request ->
          send(owner, {:provider_started, self()})

          receive do
            :finish -> [{:done, :stop}]
          end
        end
      ]

      {session, _provider} = start(context, script: script, tools: [Tools.Read])
      :ok = Session.prompt(session, "wait")
      assert_receive {:provider_started, provider_task}

      assert {:error, :busy} = Session.disable_tools(session, ["read"])
      assert {:error, :busy} = Session.enable_tools(session, ["read"])

      send(provider_task, :finish)
      assert_receive {:lemieux, _, {:finished, _}}
    end
  end

  describe "seq" do
    test "numbers entries in the order they were appended", context do
      {session, _provider} =
        start(context, script: [[{:text_delta, "hi"}, {:done, :stop}]])

      :ok = Session.prompt(session, "hello")
      assert_receive {:lemieux, _, {:finished, _}}

      assert {:ok, entries} = Store.read(context.store, Session.id(session))
      assert Enum.map(entries, & &1.seq) == Enum.to_list(0..5)
    end

    test "a resumed session carries on numbering rather than starting again", context do
      {session, _provider} = start(context, script: [[{:text_delta, "hi"}, {:done, :stop}]])
      :ok = Session.prompt(session, "hello")
      assert_receive {:lemieux, _, {:finished, _}}
      id = stop(context, session)

      {resumed, _provider} =
        resume(context, id, script: [[{:text_delta, "again"}, {:done, :stop}]])

      :ok = Session.prompt(resumed, "more")
      assert_receive {:lemieux, ^id, {:finished, _}}

      assert {:ok, entries} = Store.read(context.store, id)
      assert Enum.map(entries, & &1.seq) == Enum.to_list(0..10)
    end
  end
end

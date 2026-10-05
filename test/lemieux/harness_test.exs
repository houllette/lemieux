defmodule Lemieux.HarnessTest do
  use ExUnit.Case, async: true

  doctest Lemieux.Harness

  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool
  alias Lemieux.Tool.Override
  alias Lemieux.Tools

  # An extension with every callback: it wraps `bash` with an audit and says
  # which log it was given.
  defmodule Audited do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]

    @impl true
    def init(opts) do
      case Keyword.fetch(opts, :log) do
        {:ok, log} -> {:ok, log}
        :error -> {:error, :no_log}
      end
    end

    @impl true
    def apply(harness, log) do
      Harness.update_tools(harness, fn tools ->
        Tool.decorate(tools, %{
          "bash" =>
            &Override.new!(&1,
              digest: "audit-#{log}",
              after: fn return, _args, _ctx -> return end
            )
        })
      end)
    end

    @impl true
    def describe(log), do: %{"log" => log}
  end

  # An extension with only the required callback.
  defmodule Terse do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]

    @impl true
    def apply(harness, state), do: %{harness | max_turns: Keyword.get(state, :turns, 7)}
  end

  defmodule NotAnExtension do
    def hello, do: :world
  end

  defmodule Broken do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]

    @impl true
    def apply(_harness, _state), do: :oops
  end

  # An extension that replaces the catalog, undoing every wrap before it.
  defmodule Reset do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]

    @impl true
    def apply(harness, _state), do: Harness.put_tools(harness, [Tools.Read])
  end

  describe "new/1 and session_options/1" do
    test "explicit nil has different meaning from unset for nullable settings" do
      harness = Harness.new(compact_at: nil, reasoning_effort: nil)
      assert Harness.session_options(harness) == [compact_at: nil, reasoning_effort: nil]
      assert Harness.session_options(Harness.new()) == []
    end

    test "unset fields are omitted, so the session's own defaults apply" do
      assert Harness.session_options(Harness.new()) == []
    end

    test "a set field is passed under the session option of the same name" do
      harness = Harness.new(max_turns: 3, tools: [Tools.Read], hooks: [], compact_at: 0.5)

      assert Harness.session_options(harness) == [
               tools: [Tools.Read],
               hooks: [],
               max_turns: 3,
               compact_at: 0.5
             ]
    end

    test "system distinguishes unset from no prompt" do
      refute Keyword.has_key?(Harness.session_options(Harness.new()), :system)
      assert Harness.session_options(Harness.new(system: nil)) == [system: nil]
      assert Harness.session_options(Harness.new(system: "be terse")) == [system: "be terse"]
    end

    test "host fields are not session options" do
      harness =
        Harness.new(
          theme: "light",
          status_line: MyHost.Status,
          notices: ["x"],
          skills: [1],
          keys: %{"ctrl-j" => "submit"},
          layout: MyHost.Layout
        )

      assert Harness.session_options(harness) == []
    end

    # The key map and the layout are the screen's, like the theme: a field
    # here so an extension can set them and the config file's `"keys"` has
    # somewhere to land, and nil until somebody does, which the screen reads
    # as its own default. The map form is what `Lemieux.TUI.Keys` reads.
    test "keys and layout are host fields, unset by default" do
      assert :keys in Harness.host_fields()
      assert :layout in Harness.host_fields()

      assert %Harness{keys: nil, layout: nil} = Harness.new()

      harness = Harness.new(keys: %{"ctrl-j" => "submit"}, layout: MyHost.Layout)
      assert harness.keys == %{"ctrl-j" => "submit"}
      assert harness.layout == MyHost.Layout
    end

    test "a misspelled field raises rather than disappearing" do
      assert_raise KeyError, fn -> Harness.new(max_turn: 3) end
    end

    test "every session field is one Lemieux.Session documents" do
      documented =
        Lemieux.Session
        |> Code.fetch_docs()
        |> then(fn {:docs_v1, _, _, _, _, _, docs} -> docs end)
        |> Enum.find_value(fn
          {{:function, :start_link, 1}, _, _, %{"en" => doc}, _} -> doc
          _other -> nil
        end)

      for field <- Harness.session_fields() do
        assert documented =~ "`:#{field}`", "#{field} is not a documented session option"
      end
    end
  end

  describe "update helpers" do
    test "update_tools materialises the default catalog when unset" do
      harness = Harness.update_tools(Harness.new(), &(&1 ++ [Tools.AskUser]))

      assert harness.tools == Tools.default() ++ [Tools.AskUser]
    end

    test "update_tools transforms a catalog that is set" do
      harness =
        Harness.new(tools: [Tools.Read]) |> Harness.update_tools(&Enum.reverse([Tools.Bash | &1]))

      assert harness.tools == [Tools.Read, Tools.Bash]
    end

    test "update_system materialises the default prompt when unset and passes nil through" do
      assert Harness.update_system(Harness.new(), &(&1 <> " more")).system ==
               Lemieux.Prompt.default() <> " more"

      assert Harness.update_system(Harness.new(system: nil), &(&1 || "none")).system == "none"
    end

    test "the append helpers materialise an empty list and leave nothing alone" do
      hook = {:before_tool_call, fn _call, _context -> :allow end}

      assert Harness.append_hooks(Harness.new(), [hook]).hooks == [hook]
      assert Harness.append_hooks(Harness.new(hooks: [hook]), [hook]).hooks == [hook, hook]
      assert Harness.append_hooks(Harness.new(), []).hooks == nil

      assert Harness.append_host_tools(Harness.new(), [Tools.Read]).host_tools == [Tools.Read]
      assert Harness.append_host_tools(Harness.new(), []).host_tools == nil

      server = %{"name" => "docs", "transport" => "http", "url" => "http://x"}
      assert Harness.append_mcp_servers(Harness.new(), [server]).mcp_servers == [server]
      assert Harness.append_mcp_servers(Harness.new(), []).mcp_servers == nil
    end

    # The session runs one server per name, and used to keep the last of two
    # silently — so a plugin's server, appended after the person's own,
    # replaced it.
    test "append_mcp_servers keeps the first server of a name and says what it left out" do
      mine = %{"name" => "github", "url" => "http://mine", "source" => "personal"}
      theirs = %{"name" => "github", "url" => "http://theirs", "source" => "plugin"}
      other = %{"name" => "docs", "url" => "http://docs", "source" => "plugin"}

      harness =
        Harness.new()
        |> Harness.append_mcp_servers([mine])
        |> Harness.append_mcp_servers([theirs, other])

      assert harness.mcp_servers == [mine, other]

      assert harness.notices == [
               "Two MCP servers are named github; the one from your own settings is used, " <>
                 "and the one from a plugin is left out."
             ]
    end

    test "append_mcp_servers compares names as the session will read them" do
      first = %{name: "github", url: "http://first"}
      second = %{"name" => "github", "url" => "http://second"}

      harness = Harness.append_mcp_servers(Harness.new(), [first, second])

      assert harness.mcp_servers == [first]
      assert [notice] = harness.notices
      assert notice =~ "the one from the host is used"
    end

    test "update_harness_context materialises an empty map" do
      harness = Harness.update_harness_context(Harness.new(), &Map.put(&1, "a", 1))

      assert harness.harness_context == %{"a" => 1}
    end
  end

  describe "assemble/2" do
    test "applies extensions left to right and records each one" do
      assert {:ok, harness} =
               Harness.assemble(Harness.new(), [{Audited, log: "ops"}, {Terse, turns: 2}, Terse])

      assert %Override{tool: Tools.Bash} = Enum.find(harness.tools, &(Tool.name(&1) == "bash"))
      assert harness.max_turns == 7

      assert [
               %{"module" => "Lemieux.HarnessTest.Audited", "options" => %{"log" => "ops"}},
               %{"module" => "Lemieux.HarnessTest.Terse", "options" => %{}},
               %{"module" => "Lemieux.HarnessTest.Terse", "options" => %{}}
             ] = harness.applied

      digest = &Base.encode16(&1.module_info(:md5), case: :lower)

      assert Enum.map(harness.applied, & &1["digest"]) == [
               digest.(Audited),
               digest.(Terse),
               digest.(Terse)
             ]
    end

    test "order matters: a later extension sees what an earlier one did" do
      assert {:ok, wrapped_then_reset} =
               Harness.assemble(Harness.new(), [{Audited, log: "a"}, Reset])

      assert wrapped_then_reset.tools == [Tools.Read]

      # Reset first leaves no `bash` for the audit to wrap, and
      # `Lemieux.Tool.decorate/2` says a missing name is an error rather than
      # an audit that was never installed.
      assert_raise ArgumentError, fn ->
        Harness.assemble(Harness.new(), [Reset, {Audited, log: "a"}])
      end
    end

    test "provenance is folded into the harness context the snapshot records" do
      assert {:ok, harness} =
               Harness.assemble(
                 Harness.new(
                   harness_context: %{"extensions" => %{"session_profile" => %{"kind" => "x"}}}
                 ),
                 [Terse]
               )

      context = Harness.session_options(harness)[:harness_context]
      assert context["extensions"]["session_profile"] == %{"kind" => "x"}
      assert [%{"module" => "Lemieux.HarnessTest.Terse"}] = context["extensions"]["applied"]
    end

    test "an init that refuses stops the fold and names the module" do
      assert Harness.assemble(Harness.new(), [Terse, Audited]) == {:error, {Audited, :no_log}}
    end

    test "a module that is not an extension is refused" do
      assert Harness.assemble(Harness.new(), [NotAnExtension]) ==
               {:error, {NotAnExtension, :not_an_extension}}
    end

    test "an apply that returns something other than a harness raises" do
      assert_raise ArgumentError, ~r/must return a %Lemieux.Harness{}/, fn ->
        Harness.assemble(Harness.new(), [Broken])
      end
    end
  end

  describe "Lemieux.start_session/1 with a harness" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      runtime = :"lemieux_harness_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})
      %{runtime: runtime, store: JSONL.new(tmp_dir)}
    end

    test "the harness shapes the session and the snapshot records which extensions did",
         context do
      owner = self()

      provider =
        Scripted.new([
          fn request ->
            send(owner, {:request, request})
            Scripted.complete("ok")
          end
        ])

      assert {:ok, harness} =
               Harness.assemble(Harness.new(), [{Audited, log: "ops"}, {Terse, turns: 4}])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self(),
          harness: harness
        )

      :ok = Session.prompt(session, "hello")
      assert_receive {:request, request}, 5_000
      assert Enum.map(request.tools, &Tool.name/1) == ~w(read write edit bash)
      assert %Override{digest: "audit-ops"} = Enum.find(request.tools, &(Tool.name(&1) == "bash"))
      assert :sys.get_state(session).max_turns == 4

      snapshot =
        Enum.find_value(Session.snapshot(session).entries, fn entry ->
          if entry.type == :harness_snapshot, do: entry.payload
        end)

      assert [
               %{"module" => "Lemieux.HarnessTest.Audited"},
               %{"module" => "Lemieux.HarnessTest.Terse"}
             ] =
               snapshot["extensions"]["applied"]
    end

    test "an explicit option wins over the harness, and harness contexts merge", context do
      assert {:ok, harness} =
               Harness.assemble(Harness.new(harness_context: %{"a" => %{"b" => 1}}), [
                 {Terse, turns: 4}
               ])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: Scripted.new([]),
          store: context.store,
          model: "test:model",
          harness: harness,
          max_turns: 9,
          harness_context: %{"a" => %{"c" => 2}}
        )

      state = :sys.get_state(session)
      assert state.max_turns == 9
      assert state.evidence.harness_context["a"] == %{"b" => 1, "c" => 2}

      assert [%{"module" => "Lemieux.HarnessTest.Terse"}] =
               state.evidence.harness_context["extensions"]["applied"]
    end

    test "resuming with a harness composes over the transcript when the host seeds it", context do
      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: Scripted.new([]),
          store: context.store,
          model: "test:model",
          tools: [Tools.Read, Tools.Bash]
        )

      id = Session.id(session)
      :ok = GenServer.stop(session)

      {:ok, entries} = Lemieux.Store.read(context.store, id)

      recorded =
        entries |> Enum.filter(&(&1.type == :session)) |> List.last() |> Map.fetch!(:payload)

      seeded = Harness.new(tools: Enum.map(recorded["tools"], &String.to_existing_atom/1))
      assert {:ok, harness} = Harness.assemble(seeded, [{Audited, log: "ops"}])

      {:ok, resumed} =
        Lemieux.resume_session(
          supervisor: context.runtime,
          provider: Scripted.new([]),
          store: context.store,
          resume: id,
          harness: harness
        )

      assert Session.snapshot(resumed).tools == ["read", "bash"]

      assert %Override{digest: "audit-ops"} =
               Enum.find(Session.tools(resumed), &(Tool.name(&1) == "bash"))
    end

    test "something that is not a harness is refused loudly", context do
      assert_raise ArgumentError, ~r/:harness must be/, fn ->
        Lemieux.start_session(supervisor: context.runtime, harness: %{tools: []})
      end
    end
  end
end

defmodule Lemieux.CLI.ExtensionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Lemieux.CLI.Extensions
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  # Loading prepends directories to the VM's code path, and the VM is shared
  # with every other test. Whatever a test added comes off again on exit, so a
  # later freeze walking the code path does not meet this test's throwaway
  # ebins.
  setup do
    before = :code.get_path()
    on_exit(fn -> Enum.each(:code.get_path() -- before, &Code.delete_path/1) end)
    :ok
  end

  # A host's own extension, to prove where a loaded one lands relative to it.
  defmodule HostAudit do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]

    @impl true
    def apply(harness, _state), do: %{harness | max_turns: 3}
  end

  # An extension that appends a tool of its own, so a session it shaped is
  # distinguishable from one it did not: nothing else equips `ping_*`.
  defp source(module, opts \\ []) do
    apply_arity = Keyword.get(opts, :apply_arity, 2)
    tool = "ping_#{System.unique_integer([:positive])}"

    """
    defmodule #{module}.Ping do
      @behaviour Lemieux.Tool
      def name, do: #{inspect(tool)}
      def description, do: "answers pong"
      def schema, do: %{"type" => "object", "properties" => %{}}
      def run(_args, _context), do: {:ok, "pong"}
    end

    defmodule #{module} do
      #{if apply_arity == 2, do: "@behaviour Lemieux.Extension", else: ""}
      import Kernel, except: [apply: 2]

      def init(opts), do: {:ok, Keyword.fetch!(opts, :config)}

      #{if apply_arity == 2 do
      "def apply(harness, _config), do: Lemieux.Harness.update_tools(harness, &(&1 ++ [#{module}.Ping]))"
    else
      "def apply(harness), do: harness"
    end}

      def describe(config), do: config
    end
    """
  end

  defp unique_module(prefix),
    do: Module.concat([__MODULE__, "#{prefix}#{System.unique_integer([:positive])}"])

  # Compiles the source, writes every module it defines into `ebin`, and
  # unloads them from this VM: the loader has to find them through the path it
  # prepended, or the test proves nothing about loading.
  defp write_beams(ebin, source) do
    File.mkdir_p!(ebin)

    for {module, binary} <- Code.compile_string(source) do
      File.write!(Path.join(ebin, "#{module}.beam"), binary)
      unload(module)
      module
    end
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
    refute Code.ensure_loaded?(module), "#{inspect(module)} is still loaded"
  end

  defp write_manifest(directory, attrs) do
    File.mkdir_p!(directory)

    manifest =
      %{"schema_version" => 1, "name" => "audit", "versions" => Extensions.versions()}
      |> Map.merge(attrs)

    File.write!(Path.join(directory, "extension.json"), JSON.encode!(manifest))
    manifest
  end

  # A complete, loadable ebin extension under `directory`, returning its module.
  defp ebin_extension(directory, attrs \\ %{}) do
    module = unique_module("Ebin")
    write_beams(Path.join(directory, "lib/audit/ebin"), source(module))

    write_manifest(
      directory,
      Map.merge(%{"module" => inspect(module), "ebin" => ["lib/audit/ebin"]}, attrs)
    )

    module
  end

  defp prepare(argv, tmp_dir, opts \\ []) do
    assert {:ok, options} = Options.parse(argv)

    Runtime.prepare(
      options,
      [provider: Scripted.new([]), store: JSONL.new(Path.join(tmp_dir, "sessions"))] ++ opts
    )
  end

  test "loading reports each selected directory once and reports a failed load", %{tmp_dir: dir} do
    bundle = Path.join(dir, "audit")
    ebin_extension(bundle)
    owner = self()
    report = fn id, text, status -> send(owner, {:step, id, text, status}) end

    assert {:ok, [_]} =
             Extensions.load_all([{:dir, bundle}, {:dir, bundle}], startup_step: report)

    assert_receive {:step, id, "Load extension audit", "busy"}
    assert_receive {:step, ^id, "Load extension audit", "ok"}
    refute_received {:step, ^id, _, _}

    assert {:error, _} =
             Extensions.load_all([{:dir, Path.join(dir, "missing")}], startup_step: report)

    assert_receive {:step, failed, "Load extension missing", "busy"}
    assert_receive {:step, ^failed, "Load extension missing", "fail"}
  end

  describe "lmx run --extension-dir" do
    test "an ebin extension shapes the session and is recorded with its digests", %{
      tmp_dir: tmp_dir
    } do
      directory = Path.join(tmp_dir, "audit")
      module = ebin_extension(directory, %{"options" => %{"log" => "/var/log/agents.log"}})

      assert {:ok, prepared} =
               prepare(["--extension-dir", directory], tmp_dir, extensions: [HostAudit])

      harness = prepared.harness
      assert Module.concat(module, Ping) in harness.tools

      # After what lmx equips, before the host's own.
      assert Enum.map(harness.applied, & &1["module"]) == [
               "Lemieux.Extensions.Search",
               "Lemieux.Extensions.ApplyPatch",
               "Lemieux.Extensions.Planning",
               "Lemieux.Extensions.Continuation",
               "Lemieux.Extensions.Budget",
               "Lemieux.Extensions.Delegation",
               inspect(module),
               "Lemieux.CLI.ExtensionsTest.HostAudit"
             ]

      # The manifest's options reached `init/1` as a string-keyed map.
      applied = Enum.find(harness.applied, &(&1["module"] == inspect(module)))
      assert applied["options"] == %{"log" => "/var/log/agents.log"}

      assert [loaded] = harness.harness_context["extensions"]["loaded"]
      assert loaded["name"] == "audit"
      assert loaded["directory"] == directory
      assert loaded["module"] == inspect(module)
      assert loaded["manifest_sha256"] =~ ~r/^[0-9a-f]{64}$/
      assert loaded["ebin"] == ["lib/audit/ebin"]

      # The extension's own digest matches the one `assemble/2` recorded for
      # it; what it carried is a count and one digest over every beam rather
      # than the beams themselves, which grew the snapshot by a line per
      # module of every dependency.
      assert loaded["module_digest"] == applied["digest"]
      assert loaded["beam_count"] == 2
      assert loaded["beams_sha256"] =~ ~r/^[0-9a-f]{64}$/
      refute Map.has_key?(loaded, "beams")
    end

    test "a script extension is compiled and applied", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "scripted")
      module = unique_module("Script")
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "extension.exs"), source(module))
      write_manifest(directory, %{"module" => inspect(module), "script" => "extension.exs"})

      assert {:ok, prepared} = prepare(["--extension-dir", directory], tmp_dir)

      assert Module.concat(module, Ping) in prepared.harness.tools
      assert [loaded] = prepared.harness.harness_context["extensions"]["loaded"]
      assert loaded["script"] == "extension.exs"
      assert loaded["script_sha256"] =~ ~r/^[0-9a-f]{64}$/
      refute Map.has_key?(loaded, "module_digest")
      refute Map.has_key?(loaded, "beams_sha256")
    end

    test "two directories apply in the order given", %{tmp_dir: tmp_dir} do
      first = Path.join(tmp_dir, "first")
      second = Path.join(tmp_dir, "second")
      first_module = ebin_extension(first)
      second_module = ebin_extension(second, %{"name" => "second"})

      assert {:ok, prepared} =
               prepare(["--extension-dir", second, "--extension-dir", first], tmp_dir)

      assert Enum.map(prepared.harness.applied, & &1["module"]) == [
               "Lemieux.Extensions.Search",
               "Lemieux.Extensions.ApplyPatch",
               "Lemieux.Extensions.Planning",
               "Lemieux.Extensions.Continuation",
               "Lemieux.Extensions.Budget",
               "Lemieux.Extensions.Delegation",
               inspect(second_module),
               inspect(first_module)
             ]

      assert Enum.map(prepared.harness.harness_context["extensions"]["loaded"], & &1["name"]) ==
               ["second", "audit"]
    end

    test "nothing selected records nothing", %{tmp_dir: tmp_dir} do
      assert {:ok, prepared} = prepare([], tmp_dir)

      refute get_in(prepared.harness.harness_context || %{}, ["extensions", "loaded"])
    end
  end

  describe "an extension that offers model routes" do
    alias Lemieux.CLI.ProviderMux
    alias Lemieux.Provider
    alias LemieuxTest.StaticRoute

    # A route source and nothing else: no `apply/2`, so it shapes no harness.
    defp route_source(module, opts) do
      apply? = Keyword.get(opts, :apply?, false)

      """
      defmodule #{inspect(module)} do
        @behaviour Lemieux.Extension.Routes
        #{if apply?, do: "@behaviour Lemieux.Extension", else: ""}
        import Kernel, except: [apply: 2]

        @impl Lemieux.Extension.Routes
        def routes(config: config) do
          name = Map.fetch!(config, "name")

          {:ok,
           [
             %{
               name: name,
               route:
                 {LemieuxTest.StaticRoute,
                  LemieuxTest.StaticRoute.new(name: name, models: ["a", "b"], default: name <> ":a")}
             }
           ]}
        end

        #{if apply?, do: "@impl Lemieux.Extension\n  def apply(harness, _config), do: %{harness | max_turns: 7}", else: ""}
      end
      """
    end

    defp route_extension(directory, module, manifest \\ %{}, opts \\ []) do
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "route.exs"), route_source(module, opts))

      write_manifest(
        directory,
        Map.merge(
          %{
            "name" => "relay",
            "module" => inspect(module),
            "script" => "route.exs",
            "options" => %{"name" => "relay"}
          },
          manifest
        )
      )
    end

    test "loads with routes and no spec, and is recorded as loaded but not applied", %{
      tmp_dir: tmp_dir
    } do
      directory = Path.join(tmp_dir, "relay")
      module = unique_module("RouteOnly")
      route_extension(directory, module)

      assert {:ok, loaded} = Extensions.load(directory)
      assert loaded.spec == nil
      assert loaded.routes == {module, [config: %{"name" => "relay"}]}
      assert loaded.provenance["routes"] == true

      # Without a host provider, lmx builds its own: the route beside the
      # direct connection, the start model resolved on it.
      assert {:ok, options} =
               Options.parse(["--model", "relay:@default", "--extension-dir", directory])

      assert {:ok, prepared} =
               Runtime.prepare(options, store: JSONL.new(Path.join(tmp_dir, "sessions")))

      assert prepared.model == "relay:a"
      assert prepared.routes == ["relay"]
      assert {ProviderMux, _} = provider = Keyword.fetch!(prepared.options, :provider)
      assert Provider.available_models(provider, provider: "relay") == ["relay:a", "relay:b"]

      assert {StaticRoute, %StaticRoute{readied: 1}} =
               provider |> ProviderMux.child("relay:a") |> Adapter.route()

      refute Enum.any?(prepared.harness.applied, &(&1["module"] == inspect(module)))

      assert [%{"name" => "relay", "routes" => true}] =
               prepared.harness.harness_context["extensions"]["loaded"]
    end

    test "one module may shape the harness and offer routes", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "both")
      module = unique_module("Both")

      route_extension(directory, module, %{"name" => "both", "options" => %{"name" => "both"}},
        apply?: true
      )

      assert {:ok, loaded} = Extensions.load(directory)
      assert loaded.spec == {module, [config: %{"name" => "both"}]}
      assert loaded.routes == {module, [config: %{"name" => "both"}]}

      assert {:ok, options} = Options.parse(["--extension-dir", directory])

      assert {:ok, prepared} =
               Runtime.prepare(options, store: JSONL.new(Path.join(tmp_dir, "sessions")))

      assert prepared.harness.max_turns == 7
      assert prepared.routes == ["both"]
      assert Enum.any?(prepared.harness.applied, &(&1["module"] == inspect(module)))
    end

    test "the person's extension_options reach routes/1 over the manifest's", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "extensions")
      module = unique_module("Configured")
      route_extension(Path.join(root, "relay"), module)

      config = Path.join(tmp_dir, "config.json")

      File.write!(
        config,
        ~s({"version":1,"extensions":["relay"],"extension_options":{"relay":{"name":"renamed"}}})
      )

      File.chmod!(config, 0o600)

      assert {:ok, options} = Options.parse(["--config", config, "--router", "renamed"])
      assert options.model == "renamed:@default"

      assert {:ok, prepared} =
               Runtime.prepare(options,
                 store: JSONL.new(Path.join(tmp_dir, "sessions")),
                 extensions_dir: root
               )

      assert prepared.model == "renamed:a"
      assert prepared.routes == ["renamed"]
      # `--router NAME` is the sole connection for lmx run, like `--ixway`.
      assert {Adapter, _} = Keyword.fetch!(prepared.options, :provider)
    end

    test "a host that supplies its own provider has no route registered for it", %{
      tmp_dir: tmp_dir
    } do
      directory = Path.join(tmp_dir, "relay")
      route_extension(directory, unique_module("Unused"))

      assert {:ok, prepared} = prepare(["--extension-dir", directory], tmp_dir)
      assert prepared.routes == []
      assert {Scripted, _} = Keyword.fetch!(prepared.options, :provider)
    end

    test "--router naming a route no loaded extension registers stops the start", %{
      tmp_dir: tmp_dir
    } do
      assert {:ok, options} = Options.parse(["--router", "relay"])

      assert {:error, message} =
               Runtime.prepare(options, store: JSONL.new(Path.join(tmp_dir, "sessions")))

      assert message =~ "no model route named relay is registered"
    end
  end

  describe "selection by name" do
    test "config's extensions selects by name under the personal root", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "extensions")
      module = ebin_extension(Path.join(root, "audit"))

      config = Path.join(tmp_dir, "config.json")
      File.write!(config, ~s({"version":1,"extensions":["audit"]}))

      assert {:ok, prepared} = prepare(["--config", config], tmp_dir, extensions_dir: root)

      assert Module.concat(module, Ping) in prepared.harness.tools
      assert [%{"name" => "audit"}] = prepared.harness.harness_context["extensions"]["loaded"]
    end

    test "--extension NAME selects the same way, after the config's names", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "extensions")
      configured = ebin_extension(Path.join(root, "configured"), %{"name" => "configured"})
      typed = ebin_extension(Path.join(root, "typed"), %{"name" => "typed"})

      config = Path.join(tmp_dir, "config.json")
      File.write!(config, ~s({"version":1,"extensions":["configured"]}))

      assert {:ok, prepared} =
               prepare(["--config", config, "--extension", "typed"], tmp_dir,
                 extensions_dir: root
               )

      # A config file means a state directory beside it, so the defaults that
      # need one apply, and checkpoints wraps last, over the person's tools too.
      assert Enum.map(prepared.harness.applied, & &1["module"]) == [
               "Lemieux.Extensions.Search",
               "Lemieux.Extensions.ApplyPatch",
               "Lemieux.Extensions.Planning",
               "Lemieux.Extensions.EnvironmentContext",
               "Lemieux.Extensions.Continuation",
               "Lemieux.Extensions.Verify",
               "Lemieux.Extensions.Budget",
               "Lemieux.Extensions.Delegation",
               inspect(configured),
               inspect(typed),
               "Lemieux.Extensions.Checkpoints"
             ]
    end

    test "a name is loaded once however many times it is selected", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "extensions")
      module = ebin_extension(Path.join(root, "audit"))

      config = Path.join(tmp_dir, "config.json")
      File.write!(config, ~s({"version":1,"extensions":["audit"]}))

      assert {:ok, prepared} =
               prepare(
                 [
                   "--config",
                   config,
                   "--extension",
                   "audit",
                   "--extension-dir",
                   Path.join(root, "audit")
                 ],
                 tmp_dir,
                 extensions_dir: root
               )

      assert Enum.map(prepared.harness.applied, & &1["module"]) == [
               "Lemieux.Extensions.Search",
               "Lemieux.Extensions.ApplyPatch",
               "Lemieux.Extensions.Planning",
               "Lemieux.Extensions.EnvironmentContext",
               "Lemieux.Extensions.Continuation",
               "Lemieux.Extensions.Verify",
               "Lemieux.Extensions.Budget",
               "Lemieux.Extensions.Delegation",
               inspect(module),
               "Lemieux.Extensions.Checkpoints"
             ]
    end

    test "a name with no directory is a clear error", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "extensions")

      assert {:error, message} =
               prepare(["--extension", "missing"], tmp_dir, extensions_dir: root)

      assert message =~ "missing"
      assert message =~ Path.join(root, "missing")
      assert message =~ "mix lmx.extension.build"
    end

    test "a name is a directory name, never a path or a module" do
      for name <- ["../audit", "audit/../other", "My.Extension", "", "a b"] do
        assert {:error, message} = Options.parse(["--extension", name])
        assert message =~ "--extension", "#{inspect(name)} was accepted"
      end

      assert {:ok, options} =
               Options.parse(["--extension", "audit-v2", "--extension", "review_1"])

      assert options.extensions == [name: "audit-v2", name: "review_1"]
    end

    test "flags keep the order they were typed in, across both spellings" do
      assert {:ok, options} =
               Options.parse([
                 "--extension-dir",
                 "/a",
                 "--extension",
                 "b",
                 "--extension-dir",
                 "/c"
               ])

      assert options.extensions == [dir: "/a", name: "b", dir: "/c"]
    end
  end

  describe "load/1 refuses" do
    test "an empty script cannot claim an already loaded extension", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "empty.exs"), ":ok")
      write_manifest(tmp_dir, %{"module" => inspect(HostAudit), "script" => "empty.exs"})
      assert {:error, message} = Extensions.load(tmp_dir)
      assert message =~ inspect(HostAudit)
    end

    test "a directory without a manifest", %{tmp_dir: tmp_dir} do
      assert {:error, message} = Extensions.load(tmp_dir)
      assert message =~ "extension.json"
      assert message =~ tmp_dir
    end

    test "a directory that does not exist", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "nowhere")
      assert {:error, message} = Extensions.load(missing)
      assert message =~ missing
      assert message =~ "not a directory"
    end

    test "a version built against another lemieux, Elixir or OTP, naming both sides", %{
      tmp_dir: tmp_dir
    } do
      mismatches = [
        {"lemieux", "0.0.0-elsewhere", Lemieux.version()},
        {"elixir", "1.0.0", System.version()},
        {"otp", "0", System.otp_release()}
      ]

      for {key, theirs, ours} <- mismatches do
        directory = Path.join(tmp_dir, key)
        versions = Map.put(Extensions.versions(), key, theirs)
        ebin_extension(directory, %{"versions" => versions})

        assert {:error, message} = Extensions.load(directory)
        assert message =~ theirs, "#{key}: the extension's version is not named"
        assert message =~ ours, "#{key}: this build's version is not named"
        assert message =~ "mix lmx.extension.build"
      end
    end

    test "a manifest missing a version", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "audit")
      ebin_extension(directory, %{"versions" => Map.delete(Extensions.versions(), "otp")})

      assert {:error, message} = Extensions.load(directory)
      assert message =~ "versions"
      assert message =~ "otp"
    end

    test "a module that does not export apply/2", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "audit")
      module = unique_module("NoApply")
      write_beams(Path.join(directory, "lib/audit/ebin"), source(module, apply_arity: 1))
      write_manifest(directory, %{"module" => inspect(module), "ebin" => ["lib/audit/ebin"]})

      assert {:error, message} = Extensions.load(directory)
      assert message =~ inspect(module)
      assert message =~ "apply/2"
      assert message =~ "routes/1"
    end

    test "a module the code it names does not define", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "audit")
      module = unique_module("Elsewhere")
      write_beams(Path.join(directory, "lib/audit/ebin"), source(unique_module("Actual")))
      write_manifest(directory, %{"module" => inspect(module), "ebin" => ["lib/audit/ebin"]})

      assert {:error, message} = Extensions.load(directory)
      assert message =~ inspect(module)
      assert message =~ "not defined"
    end

    test "a path that escapes the directory", %{tmp_dir: tmp_dir} do
      outside = Path.join(tmp_dir, "outside")
      module = unique_module("Outside")
      write_beams(Path.join(outside, "ebin"), source(module))

      directory = Path.join(tmp_dir, "audit")

      for path <- ["../outside/ebin", "/" <> Path.relative_to(outside, "/") <> "/ebin", "./lib"] do
        write_manifest(directory, %{"module" => inspect(module), "ebin" => [path]})
        assert {:error, message} = Extensions.load(directory)
        assert message =~ path, "#{inspect(path)} was not refused by name"
        assert message =~ "inside"
      end

      refute Code.ensure_loaded?(module)
    end

    test "a symlinked component, even one pointing inside", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "audit")
      module = unique_module("Linked")
      real = Path.join(directory, "real/ebin")
      write_beams(real, source(module))
      File.mkdir_p!(Path.join(directory, "lib"))
      File.ln_s!(Path.join(directory, "real"), Path.join(directory, "lib/audit"))
      write_manifest(directory, %{"module" => inspect(module), "ebin" => ["lib/audit/ebin"]})

      assert {:error, message} = Extensions.load(directory)
      assert message =~ "lib/audit/ebin"
      assert message =~ "symlink"
    end

    test "a manifest that names both ways to load, or neither", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "audit")
      module = unique_module("Both")
      write_beams(Path.join(directory, "lib/audit/ebin"), source(module))
      File.write!(Path.join(directory, "extension.exs"), source(module))

      write_manifest(directory, %{
        "module" => inspect(module),
        "ebin" => ["lib/audit/ebin"],
        "script" => "extension.exs"
      })

      assert {:error, both} = Extensions.load(directory)
      assert both =~ "ebin"
      assert both =~ "script"

      write_manifest(directory, %{"module" => inspect(module)})
      assert {:error, neither} = Extensions.load(directory)
      assert neither =~ "ebin"
      assert neither =~ "script"
    end

    test "a script that does not compile, in a sentence rather than a stack trace", %{
      tmp_dir: tmp_dir
    } do
      directory = Path.join(tmp_dir, "broken")
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "extension.exs"), "defmodule Broken do\n  def apply(")
      write_manifest(directory, %{"module" => "Broken", "script" => "extension.exs"})

      stderr = capture_io(:stderr, fn -> send(self(), Extensions.load(directory)) end)
      assert_received {:error, message}
      assert message =~ "extension.exs"
      assert message =~ "compile"
      refute stderr =~ "** ("
    end

    test "options that are not an object", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "audit")
      ebin_extension(directory, %{"options" => ["not", "an", "object"]})

      assert {:error, message} = Extensions.load(directory)
      assert message =~ "options"
    end
  end

  describe "load/1" do
    test "ownership uses compiled modules, including computed declarations", %{tmp_dir: tmp_dir} do
      module = unique_module("Computed")

      File.write!(Path.join(tmp_dir, "extension.exs"), """
      name = #{inspect(module)}
      defmodule name do
        import Kernel, except: [apply: 2]
        def apply(harness, _), do: harness
      end
      """)

      write_manifest(tmp_dir, %{"module" => inspect(module), "script" => "extension.exs"})
      assert {:ok, %{spec: {^module, _}}} = Extensions.load(tmp_dir)
    end

    test "loads a script once per VM rather than redefining its module", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "scripted")
      module = unique_module("Once")
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "extension.exs"), source(module))
      write_manifest(directory, %{"module" => inspect(module), "script" => "extension.exs"})

      assert {:ok, first} = Extensions.load(directory)

      stderr = capture_io(:stderr, fn -> send(self(), Extensions.load(directory)) end)
      assert_received {:ok, ^first}
      refute stderr =~ "redefining"
    end

    test "returns the spec assemble/2 takes and the provenance the runtime records", %{
      tmp_dir: tmp_dir
    } do
      directory = Path.join(tmp_dir, "audit")
      module = ebin_extension(directory, %{"options" => %{"level" => 2}})

      assert {:ok, loaded} = Extensions.load(directory)
      assert loaded.spec == {module, [config: %{"level" => 2}]}
      refute Map.has_key?(loaded.provenance, "options")
      assert {:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(), [loaded.spec])
      assert Module.concat(module, Ping) in harness.tools
    end

    # The list of beams is gone from the record, so this is what has to hold
    # instead: a dependency that changed still changes the record, and the
    # extension's own digest still says which build of *it* this is.
    test "a conflicting dependency is refused before changing the code path",
         %{tmp_dir: tmp_dir} do
      module = unique_module("Carried")
      before = Path.join(tmp_dir, "before")
      after_change = Path.join(tmp_dir, "after")

      # `source/1` names a different tool each time it is called, so the two
      # Ping beams differ while the extension module's own code is the same.
      for directory <- [before, after_change] do
        write_beams(Path.join(directory, "lib/audit/ebin"), source(module))
        write_manifest(directory, %{"module" => inspect(module), "ebin" => ["lib/audit/ebin"]})
      end

      assert {:ok, %{provenance: first}} = Extensions.load(before)
      paths = :code.get_path()
      assert {:error, message} = Extensions.load(after_change)
      assert message =~ inspect(Module.concat(module, Ping))
      assert :code.get_path() == paths
      assert {:ok, %{provenance: ^first}} = Extensions.load(before)
    end

    test "private init options never enter loaded provenance", %{tmp_dir: tmp_dir} do
      module = unique_module("Private")

      File.write!(Path.join(tmp_dir, "private.exs"), """
      defmodule #{inspect(module)} do
        import Kernel, except: [apply: 2]
        def init(opts), do: {:ok, Keyword.fetch!(opts, :config)}
        def apply(harness, _state), do: harness
        def describe(_state), do: %{}
      end
      """)

      marker = "DUMMY-PRIVATE-INITIALIZATION-VALUE"

      write_manifest(tmp_dir, %{
        "module" => inspect(module),
        "script" => "private.exs",
        "options" => %{"api_key" => marker}
      })

      assert {:ok, prepared} = prepare(["--no-delegate", "--extension-dir", tmp_dir], tmp_dir)
      refute JSON.encode!(prepared.harness.harness_context) =~ marker
      assert {:ok, loaded} = Extensions.load(tmp_dir)
      assert elem(loaded.spec, 1) == [config: %{"api_key" => marker}]

      supervisor = :"lemieux_private_extension_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: supervisor})
      provider = Scripted.new([Scripted.complete("done")])
      assert {:ok, session} = Runtime.start(prepared, supervisor: supervisor, provider: provider)
      id = Lemieux.Session.id(session)
      :ok = Lemieux.Session.prompt(session, "go")
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      assert {:ok, entries} = Lemieux.Store.read(prepared.options[:store], id)
      refute inspect(entries, limit: :infinity, printable_limit: :infinity) =~ marker
    end

    test "distinct extension entry modules cannot carry conflicting lazy helpers", %{
      tmp_dir: tmp_dir
    } do
      helper = unique_module("Shared")

      bundles =
        for version <- [1, 2] do
          module = unique_module("Owner")
          directory = Path.join(tmp_dir, "bundle-#{version}")

          write_beams(Path.join(directory, "ebin"), """
          defmodule #{inspect(helper)} do
            def version, do: #{version}
          end
          defmodule #{inspect(module)} do
            import Kernel, except: [apply: 2]
            def apply(harness, _), do: %{harness | max_turns: #{inspect(helper)}.version()}
          end
          """)

          write_manifest(directory, %{"module" => inspect(module), "ebin" => ["ebin"]})
          {directory, module}
        end

      [{first, owner}, {second, _}] = bundles
      assert {:ok, _} = Extensions.load(first)
      assert {:error, message} = Extensions.load(second)
      assert message =~ inspect(helper)
      assert owner.apply(Lemieux.Harness.new(), []).max_turns == 1
    end

    test "concurrent loads of one script compile it once", %{tmp_dir: tmp_dir} do
      module = unique_module("Concurrent")
      File.write!(Path.join(tmp_dir, "extension.exs"), source(module))
      write_manifest(tmp_dir, %{"module" => inspect(module), "script" => "extension.exs"})

      stderr =
        capture_io(:stderr, fn ->
          results =
            1..4 |> Task.async_stream(fn _ -> Extensions.load(tmp_dir) end) |> Enum.to_list()

          assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
          assert length(Enum.uniq(results)) == 1
        end)

      refute stderr =~ "redefining"
    end
  end
end

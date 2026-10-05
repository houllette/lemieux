defmodule Lemieux.CLI.Extensions.BuildTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Extensions
  alias Lemieux.CLI.Extensions.Build

  @moduletag :tmp_dir

  # What the binary already carries, as the task would compute it; a literal
  # here so the test does not depend on this checkout's dependency tree.
  @shipped MapSet.new([:kernel, :stdlib, :elixir, :logger, :crypto, :lemieux, :req_llm, :req])

  defp source(module, opts) do
    behaviour =
      if Keyword.get(opts, :behaviour, true), do: "@behaviour Lemieux.Extension", else: ""

    """
    defmodule #{module} do
      #{behaviour}
      import Kernel, except: [apply: 2]
      def apply(harness, _state), do: harness
    end
    """
  end

  defp unique_module(prefix),
    do: Module.concat([__MODULE__, "#{prefix}#{System.unique_integer([:positive])}"])

  # A compiled application directory the way `_build/ENV/lib/APP` lays one
  # out: an `.app` file naming its runtime applications, whatever beams it
  # has, and optionally a `priv`.
  defp app(lib, name, opts \\ []) do
    ebin = Path.join([lib, Atom.to_string(name), "ebin"])
    # Written whole each time, as a compile would: a test that redefines an
    # application's modules must not inherit the beams of the last definition.
    File.rm_rf!(ebin)
    File.mkdir_p!(ebin)

    applications = Keyword.get(opts, :applications, [:kernel, :stdlib, :elixir])
    spec = {:application, name, [vsn: ~c"0.1.0", applications: applications]}
    File.write!(Path.join(ebin, "#{name}.app"), :io_lib.format("~p.~n", [spec]))

    for {module, binary} <- Keyword.get(opts, :modules, []) do
      File.write!(Path.join(ebin, "#{module}.beam"), binary)
    end

    for file <- Keyword.get(opts, :priv, []) do
      path = Path.join([lib, Atom.to_string(name), "priv", file])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "native")
    end

    ebin
  end

  defp compiled(module, opts \\ []), do: Code.compile_string(source(module, opts))

  defp build(tmp_dir, overrides) do
    Build.build(
      Keyword.merge(
        [
          app: :my_ext,
          lib: Path.join(tmp_dir, "_build/dev/lib"),
          output: Path.join(tmp_dir, "out"),
          shipped: @shipped,
          deps_tree: %{my_ext: [:jason, :lemieux], jason: []}
        ],
        overrides
      )
    )
  end

  defp manifest(output),
    do: output |> Path.join("extension.json") |> File.read!() |> JSON.decode!()

  describe "build/1" do
    test "copies the project and the dependencies the binary does not ship, and writes the manifest",
         %{tmp_dir: tmp_dir} do
      lib = Path.join(tmp_dir, "_build/dev/lib")
      module = unique_module("Audit")
      beams = compiled(module)

      app(lib, :my_ext,
        applications: [:kernel, :stdlib, :elixir, :lemieux, :jason],
        modules: beams
      )

      app(lib, :jason, priv: ["data.json"])
      app(lib, :lemieux, applications: [:kernel, :stdlib, :elixir, :req_llm])
      app(lib, :req_llm)

      output = Path.join(tmp_dir, "out")
      assert {:ok, %{directory: ^output, manifest: written}} = build(tmp_dir, [])

      assert File.regular?(Path.join(output, "lib/my_ext/ebin/my_ext.app"))
      assert File.regular?(Path.join(output, "lib/my_ext/ebin/#{module}.beam"))
      assert File.regular?(Path.join(output, "lib/jason/ebin/jason.app"))
      # A dependency's ordinary priv comes along, where `:code.priv_dir/1` finds it.
      assert File.regular?(Path.join(output, "lib/jason/priv/data.json"))
      refute File.exists?(Path.join(output, "lib/lemieux"))
      refute File.exists?(Path.join(output, "lib/req_llm"))

      assert manifest(output) == written

      assert written == %{
               "schema_version" => 1,
               "name" => "my_ext",
               "module" => inspect(module),
               "ebin" => ["lib/my_ext/ebin", "lib/jason/ebin"],
               "versions" => Extensions.versions(),
               "extension_api" => Lemieux.Extension.api_version()
             }
    end

    test "the directory it writes is one the loader accepts", %{tmp_dir: tmp_dir} do
      lib = Path.join(tmp_dir, "_build/dev/lib")
      module = unique_module("Loadable")
      beams = compiled(module)
      app(lib, :my_ext, applications: [:kernel, :stdlib, :elixir, :lemieux], modules: beams)

      assert {:ok, %{directory: output}} = build(tmp_dir, deps_tree: %{my_ext: [:lemieux]})

      for {compiled_module, _binary} <- beams do
        :code.purge(compiled_module)
        :code.delete(compiled_module)
        :code.purge(compiled_module)
      end

      assert {:ok, loaded} = Extensions.load(output)
      assert loaded.spec == {module, [config: %{}]}
    end

    test "follows runtime applications transitively and skips build-time dependencies", %{
      tmp_dir: tmp_dir
    } do
      lib = Path.join(tmp_dir, "_build/dev/lib")
      module = unique_module("Deep")

      app(lib, :my_ext,
        applications: [:kernel, :stdlib, :elixir, :lemieux, :jason],
        modules: compiled(module)
      )

      app(lib, :jason, applications: [:kernel, :stdlib, :elixir, :decimal])
      app(lib, :decimal)
      # In the dependency tree but not a runtime application: never copied.
      app(lib, :credo)

      assert {:ok, %{directory: output, manifest: manifest}} =
               build(tmp_dir, deps_tree: %{my_ext: [:jason, :credo, :lemieux], jason: [:decimal]})

      assert manifest["ebin"] == ["lib/my_ext/ebin", "lib/jason/ebin", "lib/decimal/ebin"]
      refute File.exists?(Path.join(output, "lib/credo"))
    end

    test "refuses a dependency with native code in its priv", %{tmp_dir: tmp_dir} do
      lib = Path.join(tmp_dir, "_build/dev/lib")
      module = unique_module("Nif")

      app(lib, :my_ext,
        applications: [:kernel, :stdlib, :elixir, :lemieux, :nifty],
        modules: compiled(module)
      )

      app(lib, :nifty, priv: ["native/libnifty.so"])

      assert {:error, message} =
               build(tmp_dir, deps_tree: %{my_ext: [:nifty, :lemieux], nifty: []})

      assert message =~ "nifty"
      assert message =~ "native"
      refute File.exists?(Path.join(tmp_dir, "out"))
    end

    test "refuses a dependency built with a NIF toolchain even before its priv is populated", %{
      tmp_dir: tmp_dir
    } do
      lib = Path.join(tmp_dir, "_build/dev/lib")
      module = unique_module("Rust")

      app(lib, :my_ext,
        applications: [:kernel, :stdlib, :elixir, :lemieux, :rusty],
        modules: compiled(module)
      )

      app(lib, :rusty)

      assert {:error, message} =
               build(tmp_dir,
                 deps_tree: %{my_ext: [:rusty, :lemieux], rusty: [:rustler_precompiled]}
               )

      assert message =~ "rusty"
      assert message =~ "rustler_precompiled"
    end

    test "picks the one module that is an extension, and asks when there are several or none",
         %{tmp_dir: tmp_dir} do
      lib = Path.join(tmp_dir, "_build/dev/lib")
      first = unique_module("First")
      second = unique_module("Second")
      # Exports apply/2 but never declared the behaviour: a helper, not a candidate.
      helper = unique_module("Helper")

      # Each compiled once and its beams reused: compiling a module again
      # redefines it, and the compiler said so in the middle of a passing run.
      first_beams = compiled(first)
      second_beams = compiled(second)
      helper_beams = compiled(helper, behaviour: false)

      app(lib, :my_ext,
        applications: [:kernel, :stdlib, :elixir, :lemieux],
        modules: first_beams ++ helper_beams
      )

      assert {:ok, %{manifest: %{"module" => chosen}}} = build(tmp_dir, deps_tree: %{my_ext: []})
      assert chosen == inspect(first)

      app(lib, :my_ext,
        applications: [:kernel, :stdlib, :elixir, :lemieux],
        modules: first_beams ++ second_beams
      )

      assert {:error, several} = build(tmp_dir, deps_tree: %{my_ext: []})
      assert several =~ inspect(first)
      assert several =~ inspect(second)
      assert several =~ "--module"

      assert {:ok, %{manifest: %{"module" => named}}} =
               build(tmp_dir, deps_tree: %{my_ext: []}, module: inspect(second))

      assert named == inspect(second)

      assert {:error, absent} =
               build(tmp_dir, deps_tree: %{my_ext: []}, module: "Nowhere.Ext")

      assert absent =~ "Nowhere.Ext"

      app(lib, :my_ext,
        applications: [:kernel, :stdlib, :elixir, :lemieux],
        modules: helper_beams
      )

      assert {:error, none} = build(tmp_dir, deps_tree: %{my_ext: []})
      assert none =~ "--module"
      assert none =~ "Lemieux.Extension"
    end

    test "replaces an earlier build rather than layering over it", %{tmp_dir: tmp_dir} do
      lib = Path.join(tmp_dir, "_build/dev/lib")
      module = unique_module("Again")
      beams = compiled(module)

      app(lib, :my_ext,
        applications: [:kernel, :stdlib, :elixir, :lemieux, :jason],
        modules: beams
      )

      app(lib, :jason)
      assert {:ok, %{directory: output}} = build(tmp_dir, [])
      assert File.dir?(Path.join(output, "lib/jason"))

      app(lib, :my_ext, applications: [:kernel, :stdlib, :elixir, :lemieux], modules: beams)
      assert {:ok, %{manifest: manifest}} = build(tmp_dir, deps_tree: %{my_ext: [:lemieux]})

      assert manifest["ebin"] == ["lib/my_ext/ebin"]
      refute File.exists?(Path.join(output, "lib/jason"))
    end

    test "a project that has not been compiled is named, not guessed at", %{tmp_dir: tmp_dir} do
      assert {:error, message} = build(tmp_dir, [])
      assert message =~ "my_ext"
      assert message =~ "compile"
    end

    test "takes a name of its own when asked", %{tmp_dir: tmp_dir} do
      lib = Path.join(tmp_dir, "_build/dev/lib")

      app(lib, :my_ext,
        applications: [:kernel, :stdlib, :elixir],
        modules: compiled(unique_module("Named"))
      )

      assert {:ok, %{manifest: %{"name" => "audit"}}} =
               build(tmp_dir, name: "audit", deps_tree: %{})

      assert {:error, message} = build(tmp_dir, name: "../audit", deps_tree: %{})
      assert message =~ "name"
    end
  end

  describe "shipped/0" do
    test "is lemieux's own application tree, transitively" do
      shipped = Build.shipped()

      for app <- [:lemieux, :req_llm, :req, :finch, :logger, :crypto, :kernel] do
        assert app in shipped, "#{app} should count as shipped"
      end

      refute :jason_absent_dep in shipped
    end
  end

  describe "default_output/1" do
    test "is the personal extensions root plus the name" do
      assert Build.default_output("audit", root: "/home/x/.lmx/extensions") ==
               "/home/x/.lmx/extensions/audit"
    end
  end
end

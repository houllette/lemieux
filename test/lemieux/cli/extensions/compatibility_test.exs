defmodule Lemieux.CLI.Extensions.CompatibilityTest do
  # Loading compiles scripts and prepends code paths: VM-global state the
  # loader serializes itself. Every module name here is unique, so the tests
  # stay independent of each other and of the loader tests beside them.
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Extensions
  alias Lemieux.CLI.Extensions.Scaffold

  @moduletag :tmp_dir

  defp unique_module(prefix),
    do: Module.concat([__MODULE__, "#{prefix}#{System.unique_integer([:positive])}"])

  defp source(module) do
    """
    defmodule #{inspect(module)} do
      @behaviour Lemieux.Extension
      import Kernel, except: [apply: 2]

      @impl true
      def init(opts), do: {:ok, Keyword.fetch!(opts, :config)}

      @impl true
      def apply(harness, _config), do: harness
    end
    """
  end

  defp script_extension(directory, versions, extra \\ %{}) do
    module = unique_module("Script")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "ext.exs"), source(module))

    manifest =
      Map.merge(
        %{
          "schema_version" => 1,
          "name" => Path.basename(directory),
          "module" => inspect(module),
          "script" => "ext.exs",
          "versions" => versions
        },
        extra
      )

    File.write!(Path.join(directory, "extension.json"), JSON.encode!(manifest))
    module
  end

  # Compiles the source into `ebin` and unloads it, so the loader has to find
  # the module through the path it prepends.
  defp ebin_extension(directory, manifest_attrs) do
    module = unique_module("Ebin")
    ebin = Path.join(directory, "lib/ext/ebin")
    File.mkdir_p!(ebin)

    for {compiled, binary} <- Code.compile_string(source(module)) do
      File.write!(Path.join(ebin, "#{compiled}.beam"), binary)
      :code.purge(compiled)
      :code.delete(compiled)
      :code.purge(compiled)
    end

    manifest =
      Map.merge(
        %{
          "schema_version" => 1,
          "name" => Path.basename(directory),
          "module" => inspect(module),
          "ebin" => ["lib/ext/ebin"]
        },
        manifest_attrs
      )

    File.write!(Path.join(directory, "extension.json"), JSON.encode!(manifest))
    module
  end

  defp current_versions, do: Extensions.versions()

  describe "script extensions" do
    test "need only a Lemieux requirement, whatever Elixir wrote them", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "requirement")
      module = script_extension(directory, %{"lemieux" => "~> 0.1"})

      assert {:ok, %{spec: {^module, [config: %{}]}}} = Extensions.load(directory)
    end

    test "a stale Elixir or OTP pin from an older manifest does not refuse the script", %{
      tmp_dir: tmp_dir
    } do
      directory = Path.join(tmp_dir, "stale-pins")

      module =
        script_extension(directory, %{
          "lemieux" => Lemieux.version(),
          "elixir" => "1.0.0",
          "otp" => "0"
        })

      assert {:ok, %{spec: {^module, _opts}}} = Extensions.load(directory)
    end

    test "a bare version means its release line", %{tmp_dir: tmp_dir} do
      version = Version.parse!(Lemieux.version())
      same_line = Path.join(tmp_dir, "same-line")
      script_extension(same_line, %{"lemieux" => "#{version.major}.#{version.minor}.0"})
      assert {:ok, _loaded} = Extensions.load(same_line)

      next_line = Path.join(tmp_dir, "next-line")
      script_extension(next_line, %{"lemieux" => "#{version.major}.#{version.minor + 1}.0"})
      assert {:error, message} = Extensions.load(next_line)
      assert message =~ "#{version.major}.#{version.minor + 1}.0"
      assert message =~ Lemieux.version()
    end

    test "a requirement this Lemieux does not satisfy is refused naming both sides", %{
      tmp_dir: tmp_dir
    } do
      directory = Path.join(tmp_dir, "future")
      module = script_extension(directory, %{"lemieux" => "~> 9.0"})

      assert {:error, message} = Extensions.load(directory)
      assert message =~ "~> 9.0"
      assert message =~ Lemieux.version()
      refute Code.ensure_loaded?(module)
    end

    test "a manifest without a Lemieux version says what to write", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "unversioned")
      script_extension(directory, %{"elixir" => System.version()})

      assert {:error, message} = Extensions.load(directory)
      assert message =~ "~> 0.8"
    end

    test "an unparseable Lemieux version is refused as such", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "garbled")
      script_extension(directory, %{"lemieux" => "latest please"})

      assert {:error, message} = Extensions.load(directory)
      assert message =~ "latest please"
      assert message =~ "neither a version"
    end
  end

  describe "compiled bundles with an extension API version" do
    test "load across a Lemieux release that kept the API", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "api")

      module =
        ebin_extension(directory, %{
          "versions" => Map.put(current_versions(), "lemieux", "0.0.1"),
          "extension_api" => Lemieux.Extension.api_version()
        })

      assert {:ok, %{spec: {^module, _opts}}} = Extensions.load(directory)
    end

    test "load when built on an older Elixir of the same major", %{tmp_dir: tmp_dir} do
      running = Version.parse!(System.version())
      directory = Path.join(tmp_dir, "older-elixir")

      module =
        ebin_extension(directory, %{
          "versions" => Map.put(current_versions(), "elixir", "#{running.major}.0.0"),
          "extension_api" => Lemieux.Extension.api_version()
        })

      assert {:ok, %{spec: {^module, _opts}}} = Extensions.load(directory)
    end

    test "are refused when built on a newer Elixir", %{tmp_dir: tmp_dir} do
      running = Version.parse!(System.version())
      newer = "#{running.major}.#{running.minor + 1}.0"
      directory = Path.join(tmp_dir, "newer-elixir")

      ebin_extension(directory, %{
        "versions" => Map.put(current_versions(), "elixir", newer),
        "extension_api" => Lemieux.Extension.api_version()
      })

      assert {:error, message} = Extensions.load(directory)
      assert message =~ newer
      assert message =~ System.version()
      assert message =~ "mix lmx.extension.build"
    end

    test "are refused on another OTP major", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "otp")

      ebin_extension(directory, %{
        "versions" => Map.put(current_versions(), "otp", "0"),
        "extension_api" => Lemieux.Extension.api_version()
      })

      assert {:error, message} = Extensions.load(directory)
      assert message =~ "OTP 0"
      assert message =~ "OTP #{System.otp_release()}"
    end

    test "are refused for another extension API", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "other-api")
      theirs = Lemieux.Extension.api_version() + 1

      ebin_extension(directory, %{
        "versions" => current_versions(),
        "extension_api" => theirs
      })

      assert {:error, message} = Extensions.load(directory)
      assert message =~ "extension API #{theirs}"
      assert message =~ "extension API #{Lemieux.Extension.api_version()}"
    end

    test "an API version that is not a positive integer is a manifest error", %{
      tmp_dir: tmp_dir
    } do
      directory = Path.join(tmp_dir, "bad-api")
      ebin_extension(directory, %{"versions" => current_versions(), "extension_api" => "1"})

      assert {:error, message} = Extensions.load(directory)
      assert message =~ "extension_api"
    end
  end

  describe "configured options" do
    test "are merged over the manifest's own, configuration winning", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "audit")

      module =
        script_extension(directory, %{"lemieux" => "~> 0.1"}, %{
          "options" => %{"log" => "/manifest.log", "level" => "info"}
        })

      assert {:ok, [%{spec: {^module, [config: config]}}]} =
               Extensions.load_all([{:dir, directory}],
                 options: %{"audit" => %{"log" => "/configured.log"}}
               )

      assert config == %{"log" => "/configured.log", "level" => "info"}
    end

    test "for an extension that is not selected change nothing", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "audit")

      module =
        script_extension(directory, %{"lemieux" => "~> 0.1"}, %{"options" => %{"log" => "a"}})

      assert {:ok, [%{spec: {^module, [config: %{"log" => "a"}]}}]} =
               Extensions.load_all([{:dir, directory}], options: %{"other" => %{"log" => "b"}})
    end

    test "must be JSON objects", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "audit")
      script_extension(directory, %{"lemieux" => "~> 0.1"})

      assert {:error, message} =
               Extensions.load_all([{:dir, directory}], options: %{"audit" => "verbose"})

      assert message =~ "audit"
      assert message =~ "JSON object"
    end
  end

  describe "list/1" do
    test "reports every extension directory with whether it would load, loading nothing", %{
      tmp_dir: tmp_dir
    } do
      root = Path.join(tmp_dir, "extensions")
      good = script_extension(Path.join(root, "good"), %{"lemieux" => "~> 0.1"})
      script_extension(Path.join(root, "future"), %{"lemieux" => "~> 9.0"})
      File.mkdir_p!(Path.join(root, "empty"))
      File.write!(Path.join(root, "not-a-directory"), "")

      assert [empty, future, listed_good] = Extensions.list(root: root)

      assert %{name: "empty", kind: :unknown, status: {:error, missing}} = empty
      assert missing =~ "extension.json"
      assert %{name: "future", kind: :script, status: {:error, refused}} = future
      assert refused =~ "~> 9.0"
      assert %{name: "good", kind: :script, status: :ok} = listed_good
      assert listed_good.module == inspect(good)
      refute Code.ensure_loaded?(good), "listing compiled the script"
    end

    test "is empty when the root does not exist", %{tmp_dir: tmp_dir} do
      assert Extensions.list(root: Path.join(tmp_dir, "nowhere")) == []
    end
  end

  describe "Scaffold.script/2" do
    test "writes a script extension the loader accepts and that shapes the prompt", %{
      tmp_dir: tmp_dir
    } do
      directory = Path.join(tmp_dir, "audit-log")

      assert {:ok, %{manifest: manifest}} = Scaffold.script(directory, "audit-log")
      assert manifest["module"] == "AuditLogExtension"
      assert manifest["versions"] == %{"lemieux" => Lemieux.version()}

      assert {:ok, %{spec: spec}} = Extensions.load(directory)

      assert {:ok, harness} =
               Lemieux.Harness.assemble(Lemieux.Harness.new(system: "base"), [spec])

      assert harness.system == "base\n\nLoaded from the audit-log extension."
    end

    test "refuses a directory that already holds files", %{tmp_dir: tmp_dir} do
      directory = Path.join(tmp_dir, "taken")
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "README.md"), "mine")

      assert {:error, message} = Scaffold.script(directory, "taken")
      assert message =~ "already has files"
      assert File.read!(Path.join(directory, "README.md")) == "mine"
    end

    test "refuses a name the loader would refuse", %{tmp_dir: tmp_dir} do
      assert {:error, message} = Scaffold.script(Path.join(tmp_dir, "x"), "../escape")
      assert message =~ "not an extension name"
    end

    test "module names start with a capital letter" do
      assert Scaffold.module_name("audit") == "AuditExtension"
      assert Scaffold.module_name("my_ext") == "MyExtExtension"
      assert Scaffold.module_name("9lives") == "Ext9lives"
    end
  end
end

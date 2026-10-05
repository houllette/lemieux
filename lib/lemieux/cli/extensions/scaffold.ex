defmodule Lemieux.CLI.Extensions.Scaffold do
  @moduledoc """
  Writes a new script extension a person can load and then edit.

  `lmx extension new NAME` is the entry point. The result is the smallest
  thing the loader accepts — an `extension.json` and one `.exs` file — because
  a script extension needs no Mix project, no build and no rebuild after a
  Lemieux patch release: it is compiled by the running `lmx` against the
  Lemieux it declares (see `Lemieux.CLI.Extensions`). A person who outgrows
  one file moves to a Mix project and `mix lmx.extension.build`; the module
  written here moves with them unchanged.

  The generated module does one harmless, visible thing — it appends its
  configured `"note"` to the system prompt — so loading it proves the loop
  works end to end before the person changes anything. It never overwrites:
  a directory that already has entries is somebody's extension.
  """

  alias Lemieux.CLI.Extensions

  @typedoc "What `script/2` wrote."
  @type written :: %{directory: Path.t(), manifest: map(), script: Path.t()}

  @doc """
  Writes a script extension named `name` into `directory`.

  Refuses a name the loader would refuse, and a directory that exists and is
  not empty. Returns the manifest it wrote, whose `"versions"` names this
  Lemieux's release line.
  """
  @spec script(directory :: Path.t(), name :: String.t()) ::
          {:ok, written()} | {:error, String.t()}
  def script(directory, name) when is_binary(directory) and is_binary(name) do
    directory = Path.expand(directory)
    module = module_name(name)
    script = "#{String.replace(name, "-", "_")}.exs"

    manifest = %{
      "schema_version" => 1,
      "name" => name,
      "module" => module,
      "script" => script,
      "versions" => %{"lemieux" => Lemieux.version()},
      "options" => %{"note" => "Loaded from the #{name} extension."}
    }

    with :ok <- valid_name(name),
         :ok <- empty(directory),
         :ok <- File.mkdir_p(directory),
         :ok <- File.write(Path.join(directory, script), source(module, name), [:exclusive]),
         :ok <-
           File.write(
             Path.join(directory, Extensions.manifest_file()),
             JSON.encode!(manifest) <> "\n",
             [:exclusive]
           ) do
      {:ok, %{directory: directory, manifest: manifest, script: Path.join(directory, script)}}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "cannot write #{directory}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  The module name `script/2` gives an extension called `name`: its words
  camel-cased, then `Extension`, so `audit-log` becomes `AuditLogExtension`.
  """
  @spec module_name(name :: String.t()) :: String.t()
  def module_name(name) when is_binary(name) do
    camel = name |> String.replace("-", "_") |> Macro.camelize()

    # A module name starts with a capital letter; a name may start with a
    # digit or an underscore, which camel-casing leaves where it was.
    if Regex.match?(~r/^[A-Z]/, camel), do: camel <> "Extension", else: "Ext" <> camel
  end

  defp valid_name(name) do
    if Extensions.valid_name?(name),
      do: :ok,
      else:
        {:error,
         "#{inspect(name)} is not an extension name: letters, digits, - and _, " <>
           "starting with a letter, digit or _"}
  end

  defp empty(directory) do
    case File.ls(directory) do
      {:ok, []} -> :ok
      {:ok, _entries} -> {:error, "#{directory} already has files; choose a new directory"}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "cannot read #{directory}: #{:file.format_error(reason)}"}
    end
  end

  defp source(module, name) do
    """
    defmodule #{module} do
      @moduledoc \"\"\"
      The #{name} extension for lmx.

      `lmx --extension #{name}` loads it once it lives under ~/.lmx/extensions/#{name}
      (or `lmx --extension-dir DIR` from anywhere). Options come from
      extension.json's "options", with ~/.lmx/config.json's
      "extension_options": {"#{name}": {...}} merged over them.

      The harness is every opinion a session holds — prompt, tools, hooks,
      compaction, limits. Replace a field to overload it, or wrap what is there
      to extend it: `Lemieux.Harness.update_tools/2`, `append_hooks/2`,
      `update_system/2`. A model-callable capability is a module implementing
      `Lemieux.Tool`, added with `update_tools/2`. See the Lemieux extension
      guide for recipes.
      \"\"\"

      @behaviour Lemieux.Extension
      import Kernel, except: [apply: 2]

      alias Lemieux.Harness

      @impl true
      def init(opts), do: {:ok, Keyword.get(opts, :config, %{})}

      @impl true
      def apply(harness, config) do
        case config["note"] do
          note when is_binary(note) and note != "" ->
            Harness.update_system(harness, fn system -> (system || "") <> "\\n\\n" <> note end)

          _none ->
            harness
        end
      end

      @impl true
      def describe(config), do: %{"note" => is_binary(config["note"])}
    end
    """
  end
end

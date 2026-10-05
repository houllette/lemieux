defmodule Lemieux.Extensions.Workspace.Plugin.Marketplace do
  @moduledoc """
  A Claude-compatible plugin marketplace catalog.

  A source may be a local path, a GitHub `owner/repo` shorthand, a git URL, or
  an HTTP(S) URL to `marketplace.json`. Remote git marketplaces are materialized
  into Lemieux's user cache so their relative plugin entries retain the same
  meaning they have upstream. Selected plugins may use relative, `github`,
  `url`, or `git-subdir` sources; no unselected plugin is downloaded.

  A remote catalog is fetched only for an explicit `--marketplace`; only a
  plugin selected with `--plugin` is materialized. Git authentication is
  delegated to the installed `git`, including its credential helper and SSH
  agent.

  A plugin pinned with `sha` is checked out at that commit — its `ref` only
  says where the clone starts — and verified before its skills are read; a
  cached checkout of the pin is reused without touching the network. A
  catalog, or a plugin without a pin, is fetched again at most once an hour
  (`:refresh_after_ms`), and when that refresh fails the copy fetched last is
  used with a diagnostic in `diagnostics` (or the plugin's), instead of the
  failure costing the session.
  """

  alias Lemieux.Extensions.Workspace.Plugin
  alias Lemieux.Extensions.Workspace.Plugin.Remote

  @type t :: %__MODULE__{
          name: String.t(),
          root: Path.t() | nil,
          path: String.t(),
          plugins: [map()],
          diagnostics: [String.t()]
        }

  @enforce_keys [:name, :root, :path, :plugins]
  defstruct [:name, :root, :path, :plugins, diagnostics: []]

  @doc """
  Reads a local or remote marketplace source.

  Options are the fetch overrides `:cache_dir`, `:get`, `:git` and
  `:refresh_after_ms` (how long a fetched catalog is reused before it is
  fetched again).
  """
  @spec read(source :: String.t(), opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def read(source, opts \\ []) when is_binary(source) and is_list(opts) do
    with {:ok, fetched} <- Remote.marketplace(source, opts),
         {:ok, manifest} <- decode(fetched.contents, fetched.path),
         {:ok, name} <- required_string(manifest, "name", fetched.path),
         {:ok, plugins} <- plugins(manifest, fetched.path) do
      {:ok,
       %__MODULE__{
         name: name,
         root: fetched.root,
         path: fetched.path,
         plugins: plugins,
         diagnostics: Enum.map(fetched.diagnostics, &"marketplace #{name}: #{&1}")
       }}
    end
  end

  @doc """
  Resolves, materializes when needed, and reads one selected plugin.

  Beside the fetch overrides `read/2` takes, `:plugin_data_dir` is where the
  plugin's persistent data directory (`${CLAUDE_PLUGIN_DATA}`) is made; see
  `Lemieux.Extensions.Workspace.Plugin.read/2`.
  """
  @spec resolve(marketplace :: t(), selector :: String.t(), opts :: keyword()) ::
          {:ok, Plugin.t()} | {:error, String.t()}
  def resolve(%__MODULE__{} = marketplace, selector, opts \\ [])
      when is_binary(selector) and is_list(opts) do
    with {:ok, plugin_name} <- selected_name(selector, marketplace.name),
         {:ok, entry} <- entry(marketplace, plugin_name),
         {:ok, root, fetched} <- plugin_root(marketplace, entry, opts),
         {:ok, plugin} <-
           Plugin.read(root,
             name: plugin_name,
             id: "#{plugin_name}@#{marketplace.name}",
             marketplace_entry: entry,
             data_root: Keyword.get(opts, :plugin_data_dir)
           ) do
      notes = Enum.map(fetched, &"plugin #{plugin_name}: #{&1}")
      {:ok, %{plugin | diagnostics: notes ++ plugin.diagnostics}}
    end
  end

  defp decode(contents, path) do
    case JSON.decode(contents) do
      {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
      {:ok, _other} -> {:error, "#{path} must contain a JSON object"}
      {:error, reason} -> {:error, "could not parse #{path}: #{inspect(reason)}"}
    end
  end

  defp required_string(map, key, path) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "#{path} needs a non-empty #{key}"}
    end
  end

  defp plugins(%{"plugins" => plugins}, _path) when is_list(plugins), do: {:ok, plugins}
  defp plugins(_manifest, path), do: {:error, "#{path} needs a plugins array"}

  defp selected_name(selector, marketplace) do
    case String.split(selector, "@", parts: 2) do
      [name, ^marketplace] when name != "" ->
        {:ok, name}

      [_name, other] ->
        {:error, "plugin #{selector} belongs to marketplace #{other}, not #{marketplace}"}

      [_name] ->
        {:error, "plugin selection needs NAME@MARKETPLACE: #{selector}"}
    end
  end

  defp entry(marketplace, name) do
    case Enum.find(marketplace.plugins, &(is_map(&1) and Map.get(&1, "name") == name)) do
      nil -> {:error, "marketplace #{marketplace.name} has no plugin #{name}"}
      entry -> {:ok, entry}
    end
  end

  defp plugin_root(%{root: nil}, %{"name" => name, "source" => "./" <> _rest}, _opts) do
    {:error,
     "plugin #{name} uses a relative source, but a direct marketplace.json URL has no " <>
       "repository root; use a git marketplace source or a remote plugin source"}
  end

  defp plugin_root(marketplace, %{"name" => name, "source" => "./" <> _rest = source}, _opts) do
    case Path.safe_relative(source, marketplace.root) do
      {:ok, relative} -> {:ok, Path.join(marketplace.root, relative), []}
      :error -> {:error, "plugin #{name} source escapes marketplace root: #{source}"}
    end
  end

  defp plugin_root(_marketplace, %{"source" => source}, opts) when is_map(source),
    do: Remote.plugin(source, opts)

  defp plugin_root(_marketplace, %{"name" => name, "source" => source}, _opts),
    do: {:error, "plugin #{name} has an unsupported source: #{inspect(source)}"}

  defp plugin_root(_marketplace, entry, _opts),
    do: {:error, "marketplace plugin #{inspect(entry["name"])} needs a source"}
end

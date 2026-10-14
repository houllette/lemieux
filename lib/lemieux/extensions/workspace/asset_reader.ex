defmodule Lemieux.Extensions.Workspace.AssetReader do
  @moduledoc """
  A host-owned read capability for selected skill assets.

  Discovery still selects and parses the native catalog. At load time a host's
  `:asset_reader` function receives the effective `Lemieux.Environment` and
  returns a capability made with `new/2`. The function is runtime host code,
  never restored from a transcript or loaded from skill instructions.

  Custom readers resolve, stat, list and read in one filesystem namespace.
  `:roots` are canonical backend paths explicitly approved by the host, not
  paths a skill or model requested; `:home` identifies that backend's credential
  locations. The loader also applies its narrower skill/plugin/repository
  containment checks. An external root grants asset reads only, never ordinary
  file access, command execution or approval authority.

  The native local and sandbox environments share the host filesystem and use
  the existing selected-asset policy. An unknown environment without a selector
  fails closed. A selector must reject environments it cannot attest; do not
  return a captured reader regardless of a replaced environment.

  For example, a host that implements this behaviour as `MyAssets` can pass
  the following runtime option to `Lemieux.Extensions.Workspace`:

      asset_reader: fn
        {MyContainer, state} ->
          {:ok, new({MyAssets, state}, roots: ["/approved/skills"], home: "/home/agent")}

        _other ->
          {:error, :unavailable}
      end

  The backend owns any mapping from catalog paths to its asset namespace.

  `resolve/2` returns canonical absolute paths, including for missing paths
  such as credential locations that may be created later. Callbacks must
  return before their host deadline and honor read/list bounds.
  The loader revalidates canonical paths before each operation. This detects
  links replaced between loads; it is not an atomic filesystem transaction.
  Hosts requiring protection against concurrent filesystem adversaries must
  supply a backend that atomically opens beneath its approved roots. Host-side
  string checks cannot provide that guarantee for a remote filesystem.
  """

  alias Lemieux.Environment
  alias Lemieux.Extensions.Workspace.Containment

  @type implementation :: {module(), term()}
  @type t :: %__MODULE__{
          implementation: implementation(),
          roots: [Path.t()] | nil,
          home: Path.t()
        }
  @type selector :: (Environment.t() -> {:ok, t()} | {:error, term()})
  @type stat :: %{type: :file | :directory | :other, size: non_neg_integer()}
  @type entry :: %{name: String.t(), type: :file | :directory | :symlink | :other}

  @callback resolve(state :: term(), path :: Path.t()) :: {:ok, Path.t()} | {:error, term()}
  @callback stat(state :: term(), path :: Path.t()) :: {:ok, stat()} | {:error, term()}
  @callback read_file(state :: term(), path :: Path.t(), max_bytes :: pos_integer()) ::
              {:ok, binary()} | {:error, term()}
  @callback list_dir(state :: term(), path :: Path.t(), max_entries :: pos_integer()) ::
              {:ok, [entry()]} | {:error, term()}

  @enforce_keys [:implementation, :roots, :home]
  @derive {Inspect, only: [:roots, :home]}
  defstruct @enforce_keys

  @doc "Creates a capability with explicit canonical asset roots and backend home."
  @spec new(implementation :: implementation(), opts :: keyword()) :: t()
  def new({module, _state} = implementation, opts) when is_atom(module) and is_list(opts) do
    roots = Keyword.fetch!(opts, :roots)
    home = Keyword.fetch!(opts, :home)

    unless is_list(roots) and Enum.all?(roots, &absolute?/1) and absolute?(home),
      do: raise(ArgumentError, "asset reader roots and home must be absolute backend paths")

    %__MODULE__{implementation: implementation, roots: roots, home: home}
  end

  @doc "The native selected-asset reader; ordinary file-tool access remains separate."
  @spec local(home :: Path.t() | nil) :: t()
  def local(home \\ nil),
    do: %__MODULE__{
      implementation: {__MODULE__.Local, nil},
      roots: nil,
      home: home || Path.expand("~")
    }

  @doc "Selects a fresh capability using the effective environment, without a host fallback."
  @spec select(
          selector :: selector() | nil,
          environment :: Environment.t(),
          home :: Path.t() | nil
        ) ::
          {:ok, t()} | {:error, String.t()}
  def select(nil, environment, home) do
    if Environment.name(environment) in [
         "Lemieux.Environment.Local",
         "Lemieux.Environment.Sandbox"
       ],
       do: {:ok, local(home)},
       else: {:error, "skill asset reader is unavailable for this environment"}
  end

  def select(selector, environment, _home) when is_function(selector, 1) do
    case selector.(environment) do
      {:ok, %__MODULE__{roots: roots} = reader} when is_list(roots) -> {:ok, reader}
      {:error, _reason} -> {:error, "skill asset reader is unavailable for this environment"}
      _invalid -> {:error, "host asset reader selector returned no scoped capability"}
    end
  end

  def select(_invalid, _environment, _home),
    do: {:error, "host asset reader selector must be a function"}

  @doc "Safe reader diagnostics; backend state and arbitrary failure terms are not exported."
  @spec error(reason :: term()) :: String.t()
  def error(:outside_asset_roots),
    do: "path is outside the approved asset roots or was replaced by a link"

  def error(:reader_unavailable), do: "skill asset reader is unavailable"
  def error(:too_large), do: "asset exceeds the read limit"

  def error(reason) when reason in [:enoent, :eacces, :eisdir, :enotdir, :eloop],
    do: reason |> :file.format_error() |> to_string()

  def error(_reason), do: "skill asset reader could not complete the operation"

  @doc false
  @spec native?(reader :: t()) :: boolean()
  def native?(%__MODULE__{implementation: {module, _state}}), do: module == __MODULE__.Local

  @doc "Resolves a path in the reader namespace; resolution alone grants no read."
  @spec resolve(reader :: t(), path :: Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def resolve(reader, path) do
    case call(reader, :resolve, [path]) do
      {:ok, real} when is_binary(real) ->
        if absolute?(real), do: {:ok, real}, else: {:error, :invalid_resolved_path}

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error, :invalid_resolved_path}
    end
  end

  @doc "Whether a canonical path is in the host's approved asset roots."
  @spec allowed?(reader :: t(), real :: Path.t()) :: boolean()
  def allowed?(%__MODULE__{roots: nil}, _real), do: true

  def allowed?(%__MODULE__{roots: roots}, real),
    do: Enum.any?(roots, &Containment.inside?(real, &1))

  @doc "Stats an authorized canonical path."
  @spec stat(reader :: t(), real :: Path.t()) :: {:ok, stat()} | {:error, term()}
  def stat(reader, real), do: authorized_call(reader, real, :stat, [])

  @doc "Reads an authorized canonical path with an enforced result bound."
  @spec read_file(reader :: t(), real :: Path.t(), max_bytes :: pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def read_file(reader, real, max_bytes) do
    case authorized_call(reader, real, :read_file, [max_bytes]) do
      {:ok, contents} when is_binary(contents) and byte_size(contents) <= max_bytes ->
        {:ok, contents}

      {:ok, _too_large} ->
        {:error, :too_large}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Lists authorized asset children with a bounded result."
  @spec list_dir(reader :: t(), real :: Path.t(), max_entries :: pos_integer()) ::
          {:ok, [entry()]} | {:error, term()}
  def list_dir(reader, real, max_entries) do
    case authorized_call(reader, real, :list_dir, [max_entries]) do
      {:ok, entries} when is_list(entries) -> {:ok, Enum.take(entries, max_entries)}
      {:error, _reason} = error -> error
    end
  end

  defp authorized_call(reader, real, operation, args) do
    # Check again immediately before the backend operation. Readers must open
    # this canonical path without following a newly substituted link.
    with {:ok, current} <- resolve(reader, real),
         true <- current == real and allowed?(reader, current) do
      call(reader, operation, [real | args])
    else
      false -> {:error, :outside_asset_roots}
      {:error, _reason} = error -> error
    end
  end

  defp call(%__MODULE__{implementation: {module, state}}, operation, args) do
    with {:module, _module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, operation, length(args) + 1) do
      apply(module, operation, [state | args])
    else
      _unavailable -> {:error, :reader_unavailable}
    end
  end

  defp absolute?(path),
    do: is_binary(path) and not String.contains?(path, <<0>>) and Path.type(path) == :absolute
end

defmodule Lemieux.Extensions.Workspace.AssetReader.Local do
  @moduledoc false
  @behaviour Lemieux.Extensions.Workspace.AssetReader
  alias Lemieux.Extensions.Workspace.AssetReader
  alias Lemieux.Extensions.Workspace.Containment

  @impl true
  @spec resolve(state :: term(), path :: Path.t()) :: {:ok, Path.t()}
  def resolve(_state, path), do: {:ok, Containment.real_path(path)}

  @impl true
  @spec stat(state :: term(), path :: Path.t()) :: {:ok, AssetReader.stat()} | {:error, term()}
  def stat(_state, path) do
    with {:ok, stat} <- File.stat(path) do
      type =
        case stat.type do
          :regular -> :file
          :directory -> :directory
          _other -> :other
        end

      {:ok, %{type: type, size: stat.size}}
    end
  end

  @impl true
  @spec read_file(state :: term(), path :: Path.t(), max_bytes :: pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def read_file(_state, path, max_bytes) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(file, max_bytes + 1) do
          :eof -> {:ok, ""}
          bytes when is_binary(bytes) and byte_size(bytes) <= max_bytes -> {:ok, bytes}
          bytes when is_binary(bytes) -> {:error, :too_large}
          {:error, _reason} = error -> error
        end
      after
        File.close(file)
      end
    end
  end

  @impl true
  @spec list_dir(state :: term(), path :: Path.t(), max_entries :: pos_integer()) ::
          {:ok, [AssetReader.entry()]} | {:error, term()}
  def list_dir(_state, path, max_entries) do
    with {:ok, names} <- File.ls(path) do
      entries =
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.take(max_entries)
        |> Enum.map(&entry(path, &1))

      {:ok, entries}
    end
  end

  defp entry(path, name) do
    type =
      case File.lstat(Path.join(path, name)) do
        {:ok, %{type: :regular}} -> :file
        {:ok, %{type: :directory}} -> :directory
        {:ok, %{type: :symlink}} -> :symlink
        _other -> :other
      end

    %{name: name, type: type}
  end
end

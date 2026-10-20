defmodule Lemieux.Learning.Asset.Reader do
  @moduledoc false
  @behaviour Lemieux.Extensions.Workspace.AssetReader
  alias Lemieux.Contract
  alias Lemieux.Extensions.Workspace.AssetReader

  @spec selector(files :: map(), skill_root :: Path.t(), host_selector :: term()) ::
          AssetReader.selector()
  def selector(files, skill_root, host_selector) do
    expected = Map.new(files, fn {path, bytes} -> {path, Contract.sha256(bytes)} end)

    fn environment ->
      with {:ok, reader} <- AssetReader.select(host_selector, environment, nil),
           {:ok, root} <- AssetReader.resolve(reader, skill_root),
           true <- AssetReader.allowed?(reader, root) do
        {:ok,
         AssetReader.new({__MODULE__, %{reader: reader, root: root, expected: expected}},
           roots: [root],
           home: reader.home
         )}
      else
        _unavailable -> {:error, :reader_unavailable}
      end
    end
  end

  @impl true
  def resolve(state, path), do: AssetReader.resolve(state.reader, path)
  @impl true
  def stat(state, path), do: AssetReader.stat(state.reader, path)

  @impl true
  def read_file(state, path, maximum) do
    relative = Path.relative_to(path, state.root)

    with expected when is_binary(expected) <- state.expected[relative],
         {:ok, bytes} <- AssetReader.read_file(state.reader, path, maximum),
         true <- Contract.sha256(bytes) == expected do
      {:ok, bytes}
    else
      _changed -> {:error, :asset_bytes_changed}
    end
  end

  @impl true
  def list_dir(state, path, maximum) do
    entries =
      state.expected
      |> Map.keys()
      |> Enum.flat_map(&entry(&1, state.root, path))
      |> Enum.uniq()
      |> Enum.sort_by(& &1.name)
      |> Enum.take(maximum)

    {:ok, entries}
  end

  defp entry(relative, root, path) do
    absolute = Path.join(root, relative)
    remaining = Path.relative_to(absolute, path)

    if remaining != absolute and not String.starts_with?(remaining, "..") do
      case Path.split(remaining) do
        [name] -> [%{name: name, type: :file}]
        [name | _] -> [%{name: name, type: :directory}]
      end
    else
      []
    end
  end
end

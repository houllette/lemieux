defmodule Lemieux.Learning.Extension.Tree do
  @moduledoc false

  alias Lemieux.Contract

  @spec files(root :: Path.t()) :: {:ok, map()} | {:error, term()}
  def files(root), do: walk(root, "", %{})

  @spec copy(source :: Path.t(), target :: Path.t()) :: :ok | {:error, term()}
  def copy(source, target) do
    with {:ok, files} <- files(source) do
      files |> Enum.sort() |> Enum.reduce_while(:ok, &copy_entry(&1, &2, source, target))
    end
  end

  defp copy_entry({path, metadata}, :ok, source, target) do
    case copy_path(Path.join(source, path), Path.join(target, path), metadata) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp copy_path(_source, target, %{"type" => "directory", "mode" => mode}) do
    with :ok <- File.mkdir_p(target), do: File.chmod(target, mode)
  end

  defp copy_path(source, target, _metadata) do
    with :ok <- File.mkdir_p(Path.dirname(target)), do: File.cp(source, target)
  end

  @spec seal(root :: Path.t(), name :: String.t(), metadata :: map()) ::
          {:ok, map()} | {:error, term()}
  def seal(root, name, metadata) do
    with {:ok, files} <- files(root) do
      receipt = Map.put(metadata, "files", Map.delete(files, name))
      receipt = Map.put(receipt, "sha256", Contract.digest(receipt))
      with :ok <- write(Path.join(root, name), receipt), do: {:ok, receipt}
    end
  end

  @spec verify(root :: Path.t(), name :: String.t(), digest :: String.t()) ::
          {:ok, map()} | {:error, term()}
  def verify(root, name, digest) do
    with {:ok, receipt} <- read(Path.join(root, name)),
         :ok <- Contract.verify_digest(receipt, "sha256"),
         true <- receipt["sha256"] == digest,
         {:ok, files} <- files(root),
         true <- Map.delete(files, name) == receipt["files"] do
      {:ok, receipt}
    else
      false -> {:error, :frozen_tree_changed}
      error -> error
    end
  end

  @spec read(path :: Path.t()) :: {:ok, map()} | {:error, term()}
  def read(path) do
    with {:ok, bytes} <- File.read(path), do: Contract.decode(bytes)
  end

  @spec write(path :: Path.t(), data :: map()) :: :ok | {:error, term()}
  def write(path, data), do: File.write(path, Contract.encode!(data), [:exclusive])

  defp walk(root, relative, files) do
    path = Path.join(root, relative)

    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} ->
        with {:ok, bytes} <- File.read(path) do
          {:ok, Map.put(files, relative, %{"sha256" => Contract.sha256(bytes), "mode" => mode})}
        end

      {:ok, %{type: :directory, mode: mode}} ->
        directory(
          root,
          relative,
          Map.put(files, relative, %{"type" => "directory", "mode" => mode})
        )

      {:ok, _other} ->
        {:error, {:unsafe_frozen_path, path}}

      error ->
        error
    end
  end

  defp directory(root, relative, files) do
    with {:ok, names} <- File.ls(Path.join(root, relative)) do
      Enum.reduce_while(Enum.sort(names), {:ok, files}, &walk_entry(&1, &2, root, relative))
    end
  end

  defp walk_entry(name, {:ok, files}, root, relative) do
    case walk(root, Path.join(relative, name), files) do
      {:ok, updated} -> {:cont, {:ok, updated}}
      error -> {:halt, error}
    end
  end
end

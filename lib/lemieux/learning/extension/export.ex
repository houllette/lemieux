defmodule Lemieux.Learning.Extension.Export do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Source-preserving export of native Elixir agent extensions.

  An extension is an ordinary Mix project implementing `Lemieux.Agent`.
  Plugins remain the separate ecosystem-compatible skills/commands format.
  `lemieux-extension.json` declares a module and an explicit list of files;
  export copies those bytes without generating or rewriting executable code.
  The owner supplies the Mix dependency, test cases and licensing terms.

  Exports carry file digests and are always `unassessed`. A checksum proves
  identity, not performance, provenance, or that loaded BEAM code matched the
  source during an earlier benchmark. Independent confirmation belongs to the
  existing experiment contracts. No raw run report is automatically copied.

  Files are limited to ordinary source, assets, tests, benchmark fixtures and
  project metadata. Paths must be canonical, relative and free of symlinks.
  Explicitly selected files can still contain secrets: the author owns their
  contents. Exports never install dependencies, compile, publish or start code.
  """

  alias Lemieux.Contract

  @manifest "lemieux-extension.json"
  @receipt "lemieux-extension-export.json"
  @root_files ~w(mix.exs mix.lock .formatter.exs README.md BUILDING.md LICENSE LICENSE.md)

  @doc "Copies a declared extension into a new directory and writes its integrity receipt."
  @spec export(root :: Path.t(), destination :: Path.t()) :: {:ok, map()} | {:error, term()}
  def export(root, destination) when is_binary(root) and is_binary(destination) do
    root = Path.expand(root)
    destination = Path.expand(destination)

    with :ok <- available(destination),
         {:ok, manifest_bytes} <- read_file(root, @manifest),
         {:ok, manifest} <- Contract.decode(manifest_bytes),
         :ok <- validate_manifest(manifest),
         {:ok, files} <- read_files(root, manifest["files"]) do
      files = Map.put(files, @manifest, manifest_bytes)
      receipt = receipt(manifest, files)

      with :ok <- write_export(destination, Map.put(files, @receipt, JSON.encode!(receipt))) do
        {:ok, receipt}
      end
    end
  end

  @doc "Checks the receipt and every declared file without loading extension code."
  @spec verify(root :: Path.t()) :: :ok | {:error, term()}
  def verify(root) when is_binary(root) do
    with {:ok, bytes} <- read_file(root, @receipt),
         {:ok, receipt} <- Contract.decode(bytes),
         :ok <- Contract.verify_version(receipt, "schema_version", 1),
         :ok <- Contract.verify_digest(receipt, "sha256"),
         {:ok, manifest_bytes} <- read_file(root, @manifest),
         {:ok, manifest} <- Contract.decode(manifest_bytes),
         :ok <- validate_manifest(manifest),
         :ok <- matching_manifest(receipt, manifest),
         :ok <- matching_files(root, receipt["files"]),
         {:ok, files} <- read_files(root, Map.keys(receipt["files"])) do
      verify_files(files, receipt["files"])
    end
  end

  defp validate_manifest(%{"schema_version" => 1, "module" => module, "files" => files})
       when is_binary(module) and is_list(files) do
    if Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/, module) do
      validate_files(files)
    else
      {:error, :invalid_extension_module}
    end
  end

  defp validate_manifest(_manifest), do: {:error, :invalid_extension_manifest}

  defp validate_files(files) do
    if Enum.all?(files, &is_binary/1) and length(files) == length(Enum.uniq(files)) and
         "mix.exs" in files and @manifest not in files and @receipt not in files and
         Enum.any?(files, &source_file?/1),
       do: :ok,
       else: {:error, :invalid_package_files}
  end

  defp source_file?(path),
    do: String.starts_with?(path, "lib/") and String.ends_with?(path, ".ex")

  defp matching_manifest(
         %{"module" => module, "files" => files, "qualification" => "unassessed"},
         manifest
       )
       when is_map(files) do
    expected = Enum.sort([@manifest | manifest["files"]])

    if module == manifest["module"] and Enum.sort(Map.keys(files)) == expected,
      do: :ok,
      else: {:error, :extension_manifest_mismatch}
  end

  defp matching_manifest(_receipt, _manifest), do: {:error, :invalid_extension_receipt}

  defp matching_files(root, files) do
    with {:ok, actual} <- source_paths(root, "") do
      if Enum.sort(actual) == Enum.sort(Map.keys(files)),
        do: :ok,
        else: {:error, :extension_file_set_mismatch}
    end
  end

  defp source_paths(root, relative) do
    with {:ok, names} <- File.ls(Path.join(root, relative)) do
      source_names(root, relative, names)
    end
  end

  defp source_names(root, relative, names) do
    names
    |> Enum.reject(&(relative == "" and &1 in [@receipt, "_build", "deps", ".git", "tmp"]))
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, paths} ->
      path = if relative == "", do: name, else: Path.join(relative, name)

      case source_path(root, path) do
        {:ok, found} -> {:cont, {:ok, found ++ paths}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp source_path(root, path) do
    case File.lstat(Path.join(root, path)) do
      {:ok, %{type: :regular}} -> {:ok, [path]}
      {:ok, %{type: :directory}} -> source_paths(root, path)
      _other -> {:error, {:unsafe_package_path, path}}
    end
  end

  defp receipt(manifest, files) do
    receipt = %{
      "schema_version" => 1,
      "module" => manifest["module"],
      "lemieux_version" => Lemieux.version(),
      "qualification" => "unassessed",
      "files" => Map.new(files, fn {path, bytes} -> {path, Contract.sha256(bytes)} end)
    }

    Map.put(receipt, "sha256", Contract.digest(receipt))
  end

  defp read_files(root, paths) do
    Enum.reduce_while(Enum.sort(paths), {:ok, %{}}, fn path, {:ok, files} ->
      case read_file(root, path) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(files, path, bytes)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp read_file(root, path) do
    with true <- allowed_path?(path),
         {:ok, ^path} <- Path.safe_relative(path, root),
         :ok <- regular_components(root, Path.split(path)),
         {:ok, bytes} <- File.read(Path.join(root, path)) do
      {:ok, bytes}
    else
      _error -> {:error, {:unsafe_package_path, path}}
    end
  end

  defp allowed_path?(path) when is_binary(path) and byte_size(path) > 0 do
    parts = Path.split(path)

    Path.type(path) == :relative and Path.join(parts) == path and
      Enum.all?(parts, &(&1 not in [".", "..", ""])) and
      (path in [@manifest, @receipt | @root_files] or
         match?([directory, _ | _] when directory in ["lib", "priv", "test", "bench"], parts))
  end

  defp allowed_path?(_path), do: false

  defp regular_components(root, [name]) do
    case File.lstat(Path.join(root, name)) do
      {:ok, %{type: :regular}} -> :ok
      _other -> :error
    end
  end

  defp regular_components(root, [name | rest]) do
    directory = Path.join(root, name)

    case File.lstat(directory) do
      {:ok, %{type: :directory}} -> regular_components(directory, rest)
      _other -> :error
    end
  end

  defp verify_files(files, hashes) do
    case Enum.find(Enum.sort(files), fn {path, bytes} ->
           Contract.sha256(bytes) != hashes[path]
         end) do
      nil -> :ok
      {path, _bytes} -> {:error, {:file_digest_mismatch, path}}
    end
  end

  defp available(destination) do
    case File.lstat(destination) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :destination_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_export(destination, files) do
    stage = destination <> ".staging-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.mkdir(stage) do
      try do
        with :ok <- write_files(stage, files),
             :ok <- available(destination) do
          File.rename(stage, destination)
        end
      after
        File.rm_rf(stage)
      end
    end
  end

  defp write_files(root, files) do
    Enum.reduce_while(files, :ok, fn {path, bytes}, :ok ->
      target = Path.join(root, path)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(target, bytes, [:exclusive]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end

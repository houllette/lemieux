defmodule Lemieux.Extensions.Capture.Inputs do
  @moduledoc false
  alias Lemieux.Benchmark.SecretFiles
  alias Lemieux.Contract
  alias Lemieux.Environment

  @skip ~w(.git .lmx _build deps node_modules .venv venv __pycache__ target)

  @spec capture(environment :: Environment.t(), cwd :: Path.t(), limits :: map()) :: map()
  def capture(environment, cwd, limits) do
    initial = %{
      files: [],
      skipped: [],
      bytes: 0,
      visited: 0,
      deadline: System.monotonic_time(:millisecond) + limits.timeout_ms
    }

    result = walk(environment, cwd, "", limits, initial)

    base = %{
      "version" => 1,
      "files" => Enum.reverse(result.files),
      "skipped" => Enum.reverse(result.skipped),
      "size_bytes" => result.bytes,
      "complete" => result.skipped == []
    }

    Map.put(base, "sha256", Contract.digest(base))
  end

  defp walk(environment, cwd, relative, limits, state) do
    path = if relative == "", do: ".", else: relative

    with false <- exhausted?(state, limits),
         true <- authorized?(limits, path),
         {:ok, entries} <- Environment.list_dir(environment, cwd, path) do
      entries
      |> Enum.sort_by(& &1.name)
      |> Enum.reduce_while(state, &visit(&1, &2, environment, cwd, relative, limits))
    else
      _unavailable -> skip(state, path, "unavailable_or_input_limit")
    end
  end

  defp visit(entry, state, environment, cwd, relative, limits) do
    if exhausted?(state, limits),
      do: {:halt, skip(state, relative, "input_limit")},
      else:
        {:cont,
         next(environment, cwd, relative, entry, limits, %{state | visited: state.visited + 1})}
  end

  defp authorized?(%{authorize: authorize}, path), do: authorize.(path)
  defp authorized?(_limits, _path), do: true

  defp next(environment, cwd, parent, %{name: name, type: type}, limits, state) do
    path = Path.join(parent, name)

    cond do
      not safe_name?(name) -> skip(state, parent, "invalid_path")
      name in @skip -> skip(state, path, "excluded_directory")
      SecretFiles.secret?(name) -> skip(state, path, "credential_name")
      type == :directory -> walk(environment, cwd, path, limits, state)
      type == :file -> file(environment, cwd, path, limits, state)
      true -> skip(state, path, "unsupported_type")
    end
  end

  defp file(environment, cwd, path, limits, state) do
    budget = min(limits.max_file_bytes, limits.max_input_bytes - state.bytes)

    with true <- authorized?(limits, path),
         {:ok, stream} <- stream_file(environment, cwd, path),
         {:ok, bytes} <- bounded(stream, budget, state.deadline) do
      value = %{
        "path" => path,
        "sha256" => Contract.sha256(bytes),
        "size_bytes" => byte_size(bytes),
        "content" => Base.encode64(bytes)
      }

      %{state | files: [value | state.files], bytes: state.bytes + byte_size(bytes)}
    else
      _unavailable -> skip(state, path, "unavailable_or_oversized")
    end
  end

  defp bounded(stream, budget, deadline) do
    Enum.reduce_while(stream, {:ok, ""}, fn bytes, {:ok, acc} ->
      if byte_size(acc) + byte_size(bytes) <= budget and
           System.monotonic_time(:millisecond) <= deadline,
         do: {:cont, {:ok, acc <> bytes}},
         else: {:halt, {:error, :input_limit}}
    end)
  end

  defp exhausted?(state, limits),
    do:
      state.visited >= limits.max_files or
        state.bytes >= limits.max_input_bytes or
        System.monotonic_time(:millisecond) > state.deadline

  defp skip(state, path, reason),
    do: %{state | skipped: [%{"path" => path, "reason" => reason} | state.skipped]}

  defp safe_name?(name),
    do:
      is_binary(name) and String.valid?(name) and name not in ["", ".", ".."] and
        not String.contains?(name, ["/", "\\", <<0>>])

  @doc false
  @spec stream_file(environment :: Environment.t(), cwd :: Path.t(), path :: Path.t()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream_file({module, state}, cwd, path) do
    if Code.ensure_loaded?(module) and function_exported?(module, :stream_file, 3),
      do: module.stream_file(state, cwd, path),
      else: {:error, :unsupported}
  end

  def stream_file(module, cwd, path), do: stream_file({module, nil}, cwd, path)

  @spec materialize(input :: map(), destination :: Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def materialize(input, destination) do
    with :ok <- verify(input),
         false <- File.exists?(destination),
         :ok <- File.mkdir_p(destination),
         :ok <- File.chmod(destination, 0o700) do
      Enum.reduce_while(input["files"], {:ok, destination}, &write_file/2)
    else
      true -> {:error, :destination_exists}
      error -> error
    end
  end

  defp write_file(file, {:ok, destination}) do
    path = Path.join(destination, file["path"])

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Base.decode64!(file["content"]), [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      {:cont, {:ok, destination}}
    else
      error -> {:halt, error}
    end
  end

  @spec verify(input :: map()) :: :ok | {:error, term()}
  def verify(
        %{"version" => 1, "files" => files, "skipped" => skipped, "size_bytes" => size} = input
      )
      when is_list(files) and is_list(skipped) and length(files) <= 512 and is_integer(size) and
             size <= 1_048_576 do
    with :ok <- Contract.verify_digest(input, "sha256"),
         true <- input["complete"] == (skipped == []),
         true <- Enum.all?(files, &valid_file?/1),
         true <- size == Enum.sum(Enum.map(files, & &1["size_bytes"])),
         paths = Enum.map(files, & &1["path"]),
         true <- paths == Enum.uniq(paths) do
      :ok
    else
      _invalid -> {:error, :invalid_capture_inputs}
    end
  end

  def verify(_invalid), do: {:error, :invalid_capture_inputs}

  defp valid_file?(%{"path" => path, "content" => content, "sha256" => sha, "size_bytes" => size})
       when is_binary(path) and is_binary(content) and is_integer(size) and size >= 0 do
    with true <-
           Path.type(path) == :relative and Enum.all?(String.split(path, "/"), &safe_name?/1),
         false <- Enum.any?(String.split(path, "/"), &(SecretFiles.secret?(&1) or &1 in @skip)),
         {:ok, bytes} <- Base.decode64(content) do
      byte_size(bytes) == size and Contract.sha256(bytes) == sha
    else
      _invalid -> false
    end
  end

  defp valid_file?(_invalid), do: false
end

defmodule Lemieux.Extensions.Capture.Storage do
  @moduledoc false
  alias Lemieux.Contract
  alias Lemieux.Extensions.Capture

  @spec scope(cwd :: Path.t()) :: map()
  def scope(cwd), do: %{"id" => "local/" <> Contract.sha256(Path.expand(cwd))}
  @spec directory(root :: Path.t(), scope :: map()) :: Path.t()
  def directory(root, scope), do: Path.join(root, Contract.digest(scope))

  @spec write(root :: Path.t(), scope :: map(), name :: String.t(), value :: map()) ::
          :ok | {:error, term()}
  def write(root, scope, name, value) do
    dir = directory(root, scope)

    with true <- Regex.match?(~r/\A(?:capture|input)_[a-f0-9]{64}\.json\z/, name),
         :ok <- ancestors(dir),
         :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(root, 0o700),
         :ok <- File.chmod(dir, 0o700),
         :ok <- ignored(dir),
         :ok <- publish(Path.join(dir, name), JSON.encode!(value)) do
      :ok
    else
      false -> {:error, :invalid_capture_id}
      error -> error
    end
  end

  @spec read(root :: Path.t(), scope :: map(), name :: String.t()) ::
          {:ok, map()} | {:error, term()}
  def read(root, scope, name) do
    path = Path.join(directory(root, scope), name)

    with true <- Regex.match?(~r/\A(?:capture|input)_[a-f0-9]{64}\.json\z/, name),
         :ok <- ancestors(path),
         {:ok, %{type: :regular, size: size}} when size <= 2_097_152 <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, map} <- JSON.decode(bytes),
         true <- is_map(map),
         :ok <- Contract.verify_digest(map, "sha256") do
      {:ok, map}
    else
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_capture_record}
    end
  end

  @spec history(root :: Path.t(), scope :: map()) :: {:ok, [map()]} | {:error, term()}
  def history(root, scope) do
    dir = directory(root, scope)

    with :ok <- ancestors(dir), {:ok, names} <- names(dir), true <- length(names) <= 4096 do
      names
      |> Enum.filter(&committed?(&1, "capture_"))
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, &read_record(&1, &2, root, scope))
    else
      false -> {:error, :capture_history_limit}
      error -> error
    end
  end

  defp read_record(name, {:ok, records}, root, scope) do
    with {:ok, record} <- read(root, scope, name),
         ^scope <- record["scope"],
         :ok <- Capture.verify(record) do
      {:cont, {:ok, [record | records]}}
    else
      _invalid -> {:halt, {:error, :invalid_capture_record}}
    end
  end

  @spec cleanup(root :: Path.t(), scope :: map(), names :: [String.t()]) :: :ok
  def cleanup(root, scope, names) do
    dir = directory(root, scope)

    if ancestors(dir) == :ok do
      Enum.each(names, &remove_input(dir, &1))

      if File.ls(dir) == {:ok, [".gitignore"]} do
        File.rm(Path.join(dir, ".gitignore"))
        File.rmdir(dir)
        File.rmdir(root)
      end
    end

    :ok
  end

  defp remove_input(dir, name) do
    if Regex.match?(~r/\Ainput_[a-f0-9]{64}\.json\z/, name), do: File.rm(Path.join(dir, name))
  end

  @spec prune(
          root :: Path.t(),
          scope :: map(),
          days :: pos_integer(),
          max_records :: pos_integer(),
          now :: DateTime.t()
        ) :: :ok | {:error, term()}
  def prune(root, scope, days, max_records, now) do
    with {:ok, records} <- history(root, scope) do
      cutoff = DateTime.add(now, -days * 86_400)

      current =
        records
        |> Enum.sort_by(&{&1["created_at"], &1["id"]}, :desc)
        |> Enum.reject(&(DateTime.compare(time!(&1["created_at"]), cutoff) == :lt))
        |> Enum.take(max_records)
        |> Enum.map(& &1["id"])

      Enum.reduce_while(records, :ok, &remove_expired(&1, &2, root, scope, current))
    end
  end

  defp remove_expired(record, :ok, root, scope, current) do
    if record["id"] in current,
      do: {:cont, :ok},
      else: result(File.rm(Path.join(directory(root, scope), record["id"] <> ".json")))
  end

  @spec prune_inputs(
          root :: Path.t(),
          scope :: map(),
          days :: pos_integer(),
          maximum :: pos_integer()
        ) :: :ok | {:error, term()}
  def prune_inputs(root, scope, days, maximum) do
    with :ok <- ancestors(directory(root, scope)),
         {:ok, names} <- names(directory(root, scope)) do
      cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400)
      checkpoints = names |> Enum.filter(&committed?(&1, "input_")) |> Enum.sort(:desc)

      Enum.reduce_while(
        Enum.with_index(checkpoints),
        :ok,
        &remove_checkpoint(&1, &2, root, scope, cutoff, maximum)
      )
    end
  end

  # Hard-link publication temporarily leaves .partial files beside records;
  # a killed bounded writer can leave one permanently. They are not commits.
  # Malformed names/content ending in .json still reach strict read validation.
  defp committed?(name, prefix),
    do: String.starts_with?(name, prefix) and String.ends_with?(name, ".json")

  defp remove_checkpoint({name, index}, :ok, root, scope, cutoff, maximum) do
    with {:ok, record} <- read(root, scope, name),
         {:ok, time, 0} <- DateTime.from_iso8601(record["created_at"]) do
      if index >= maximum or DateTime.compare(time, cutoff) == :lt,
        do: result(File.rm(Path.join(directory(root, scope), name))),
        else: {:cont, :ok}
    else
      _invalid -> {:halt, {:error, :invalid_capture_checkpoint}}
    end
  end

  defp time!(value) do
    {:ok, time, 0} = DateTime.from_iso8601(value)
    time
  end

  defp result(:ok), do: {:cont, :ok}
  defp result(error), do: {:halt, error}

  defp names(dir) do
    case File.ls(dir) do
      {:error, :enoent} -> {:ok, []}
      result -> result
    end
  end

  defp ignored(dir) do
    case File.write(Path.join(dir, ".gitignore"), "*\n", [:exclusive]) do
      {:error, :eexist} -> existing_ignore(dir)
      result -> result
    end
  end

  defp existing_ignore(dir) do
    path = Path.join(dir, ".gitignore")

    with {:ok, %{type: :regular}} <- File.lstat(path), {:ok, "*\n"} <- File.read(path) do
      :ok
    else
      _conflicting -> {:error, :capture_ignore_conflict}
    end
  end

  defp publish(path, bytes) when byte_size(bytes) <= 2_097_152 do
    temporary = path <> ".partial-" <> Integer.to_string(System.unique_integer([:positive]))

    with {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]) do
      result =
        with :ok <- File.chmod(temporary, 0o600),
             :ok <- IO.binwrite(file, bytes),
             do: :file.sync(file)

      File.close(file)
      result = if result == :ok, do: link(temporary, path, bytes), else: result
      File.rm(temporary)
      result
    end
  end

  defp publish(_path, _bytes), do: {:error, :capture_record_limit}

  defp link(temporary, path, bytes) do
    case File.ln(temporary, path) do
      {:error, :eexist} ->
        if File.read(path) == {:ok, bytes}, do: :ok, else: {:error, :capture_conflict}

      result ->
        result
    end
  end

  @spec ancestors(path :: Path.t()) :: :ok | {:error, term()}
  def ancestors(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        {:error, :capture_symlink}

      {:error, reason} when reason not in [:enoent, :enotdir] ->
        {:error, reason}

      _other ->
        parent = Path.dirname(path)
        if parent == path, do: :ok, else: ancestors(parent)
    end
  end
end

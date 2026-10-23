defmodule Lemieux.CLI.Learning.Journal do
  @moduledoc false
  alias Lemieux.CLI.Learning.Installation
  alias Lemieux.Contract
  alias Lemieux.Store.JSONL

  @limit 524_288

  @spec read(root :: Path.t(), name :: String.t()) :: {:ok, map()} | {:error, term()}
  def read(root, name) do
    path = Path.join(root, name)

    with :ok <- safe(path),
         {:ok, %{type: :regular, size: size}} when size <= @limit <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, record} <- Contract.decode(bytes),
         :ok <- Contract.verify_digest(record, "sha256") do
      {:ok, record}
    else
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_learning_journal}
    end
  end

  @spec write(root :: Path.t(), name :: String.t(), value :: map()) :: :ok | {:error, term()}
  def write(root, name, value) do
    value = seal(value)
    path = Path.join(root, name)

    with true <- byte_size(Contract.encode!(value)) <= @limit,
         :ok <- safe(path),
         :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- Installation.write(path, value),
         do: File.chmod(path, 0o600)
  end

  @spec control(root :: Path.t()) :: {:ok, map()} | {:error, term()}
  def control(root) do
    case read(root, "control.json") do
      {:error, :enoent} ->
        {:ok, seal(%{"enabled" => true, "blocked" => [], "parents" => %{}, "last" => nil})}

      {:ok, %{"enabled" => enabled, "blocked" => blocked, "last" => last}} = result
      when is_boolean(enabled) ->
        if valid_control?(blocked, last) and parents?(Map.get(elem(result, 1), "parents", %{})),
          do: result,
          else: {:error, :invalid_learning_control}

      {:ok, _invalid} ->
        {:error, :invalid_learning_control}

      error ->
        error
    end
  end

  defp lesson_id?(id), do: is_binary(id) and Regex.match?(~r/\Alesson_[a-f0-9]{64}\z/, id)

  defp valid_control?(blocked, last)
       when is_list(blocked) and length(blocked) <= 1000 and
              (is_nil(last) or is_map(last)),
       do: Enum.all?(blocked, &lesson_id?/1)

  defp valid_control?(_blocked, _last), do: false

  defp parents?(parents) when is_map(parents) and map_size(parents) <= 1000,
    do: Enum.all?(parents, &parent_entry?/1)

  defp parents?(_invalid), do: false

  defp parent_entry?({id, parents}),
    do:
      lesson_id?(id) and is_list(parents) and
        length(parents) <= 2 and Enum.all?(parents, &lesson_id?/1)

  # Bounded workers are killed on timeout, bypassing their `after` cleanup.
  # Reuse the transcript store's exact local-owner/token protocol so a proven
  # dead writer cannot strand undo. Foreign and legacy directory locks refuse
  # takeover; their state is not evidence that an owner has exited.
  # Immutable receipts precede the single atomic control-file replacement.
  @spec update(root :: Path.t(), change :: function()) :: :ok | {:error, term()}
  def update(root, change) do
    lock = Path.join(root, "control.lock")

    with :ok <- safe(root),
         :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- lock_file(lock),
         {:ok, claim} <- JSONL.lock(%{dir: root}, "control") do
      try do
        with {:ok, control} <- control(root),
             {:ok, next} <- change.(control),
             do: write(root, "control.json", next)
      after
        JSONL.unlock(%{dir: root}, "control", claim)
      end
    end
  end

  defp lock_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      _ambiguous -> {:error, :unsafe_learning_lock}
    end
  end

  @spec seal(value :: map()) :: map()
  def seal(value) do
    value = Map.delete(value, "sha256")
    Map.put(value, "sha256", Contract.digest(value))
  end

  @spec safe(path :: Path.t()) :: :ok | {:error, term()}
  def safe(path) do
    case File.lstat(path) do
      {:ok, %{type: type}} when type in [:directory, :regular] -> parent(path)
      {:error, :enoent} -> parent(path)
      _unsafe -> {:error, :unsafe_learning_path}
    end
  end

  defp parent(path) do
    if Path.dirname(path) == path, do: :ok, else: safe(Path.dirname(path))
  end
end

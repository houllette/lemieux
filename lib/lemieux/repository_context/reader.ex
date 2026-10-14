defmodule Lemieux.RepositoryContext.Reader do
  @moduledoc false
  alias Lemieux.Environment

  @spec path?(path :: term()) :: boolean()
  def path?(path) when is_binary(path) and byte_size(path) in 1..1_024 do
    String.valid?(path) and Path.type(path) == :relative and
      not Regex.match?(~r/[\x00-\x1f\x7f\\]/, path) and
      Enum.all?(Path.split(path), &(&1 not in ["..", ".", ".git"])) and
      Path.join(Path.split(path)) == path
  end

  def path?(_path), do: false

  @spec allowed?(repo :: map(), context :: map(), path :: term()) :: boolean()
  def allowed?(repo, context, path), do: match?({:ok, _, _, _}, authorize(repo, context, path))

  @spec read(repo :: map(), context :: map(), path :: String.t(), max_bytes :: pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def read(repo, context, path, max_bytes) do
    with {:ok, environment, root, resolved} <- authorize(repo, context, path),
         {:ok, stream} <- Environment.stream_file(environment, root, resolved) do
      bounded(stream, max_bytes)
    end
  rescue
    # A stream may fail after it was opened (for example, a remote read or
    # filesystem error). Withhold this file without discarding other verified
    # records, and never expose the environment's raw exception text.
    _error -> {:error, :unreadable}
  catch
    _kind, _reason -> {:error, :unreadable}
  end

  defp authorize(repo, context, path) do
    if path?(path) and repo.allow.(path, context) == true do
      environment =
        if repo.environment == :session,
          do: Environment.from_context(context),
          else: repo.environment

      root = if repo.root == :session, do: context.cwd, else: repo.root

      with {:ok, resolved} <- resolve(environment, root, path),
           true <- path?(resolved),
           true <- resolved == path or repo.allow.(resolved, context) == true do
        {:ok, environment, root, resolved}
      else
        _denied -> {:error, :denied}
      end
    else
      {:error, :denied}
    end
  end

  # Check both the index's spelling and its physical target. Otherwise a
  # permitted alias inside the workspace bypasses a denied target. Remote
  # environments own physical resolution; never consult the BEAM host for it.
  defp resolve(environment, root, path) do
    if Environment.name(environment) == "Lemieux.Environment.Local" do
      case Path.safe_relative(path, root) do
        {:ok, resolved} -> {:ok, resolved}
        :error -> {:error, :denied}
      end
    else
      {:ok, path}
    end
  end

  @spec bounded(stream :: Enumerable.t(), max_bytes :: pos_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def bounded(stream, max_bytes) do
    stream
    |> Enum.reduce_while({[], 0}, fn chunk, {chunks, size} ->
      if is_binary(chunk) and size + byte_size(chunk) <= max_bytes,
        do: {:cont, {[chunk | chunks], size + byte_size(chunk)}},
        else: {:halt, :too_large}
    end)
    |> case do
      :too_large -> {:error, :source_limit}
      {chunks, _size} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  @spec digest(bytes :: binary()) :: String.t()
  def digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

defmodule Lemieux.CLI.ACP.Environment do
  @moduledoc """
  Editor text access inside the host's existing filesystem policy.

  Only the local leaf is replaced: the sandbox stays outside this adapter,
  so hidden paths and read-only policy are checked before an editor request.
  Local confinement still checks symlink escapes. A failed editor operation
  is never retried on disk: a lost acknowledgement could follow a successful
  write, and retrying would both duplicate it and bypass the editor's review.

  Directory, binary and large-file reads retain the local environment. ACP
  text reads return a whole JSON string, so using them for an unbounded log
  would discard the streaming read tool's memory bound.
  """

  @behaviour Lemieux.Environment

  alias Lemieux.Environment
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox

  @max_text_bytes 524_288
  @max_diff_bytes 65_536
  @binary_extensions ~w(.png .jpg .jpeg .gif .webp .bmp .ico .pdf .mp3 .mp4 .wav .zip .gz)

  @spec wrap(environment :: Environment.t(), bridge :: map()) :: Environment.t()
  def wrap({Sandbox, sandbox}, bridge),
    do: {Sandbox, %{sandbox | inner: wrap(sandbox.inner, bridge)}}

  def wrap({Local, _state} = inner, bridge), do: {__MODULE__, Map.put(bridge, :inner, inner)}
  def wrap(Local, bridge), do: {__MODULE__, Map.put(bridge, :inner, Local)}
  def wrap(environment, _bridge), do: environment

  @impl Environment
  def read_file(%{read?: true} = state, cwd, path) do
    with {:ok, full} <- Local.confined(cwd, path) do
      if editor_text?(full) do
        editor_read(state, full)
      else
        Environment.read_file(state.inner, cwd, path)
      end
    end
  end

  def read_file(state, cwd, path), do: Environment.read_file(state.inner, cwd, path)

  defp editor_read(state, full) do
    case state.request.("fs/read_text_file", %{"path" => full}) do
      {:ok, %{"content" => text}} when is_binary(text) -> {:ok, text}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :eio}
    end
  end

  @impl Environment
  def stream_file(state, cwd, path) do
    with {:ok, full} <- Local.confined(cwd, path) do
      if state.read? and editor_text?(full) do
        editor_stream(state, cwd, path)
      else
        Environment.stream_file(state.inner, cwd, path)
      end
    end
  end

  defp editor_stream(state, cwd, path) do
    with {:ok, content} <- read_file(state, cwd, path), do: {:ok, [content]}
  end

  @impl Environment
  def write_file(state, cwd, path, contents) do
    with {:ok, full} <- Local.confined(cwd, path),
         {:ok, old} <- previous(state, cwd, path),
         text = IO.iodata_to_binary(contents),
         {:ok, disposition} <- write(state, cwd, full, text) do
      if diff_text?(text) and (is_nil(old) or diff_text?(old)),
        do: state.notify.({:diff, full, old, text})

      {:ok, disposition}
    end
  end

  defp write(%{write?: true} = state, _cwd, full, text) do
    existed? = File.exists?(full)

    case state.request.("fs/write_text_file", %{"path" => full, "content" => text}) do
      {:ok, result} when is_map(result) -> {:ok, if(existed?, do: :overwritten, else: :created)}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :eio}
    end
  end

  defp write(state, cwd, full, text), do: Environment.write_file(state.inner, cwd, full, text)

  defp previous(state, cwd, path) do
    case read_file(state, cwd, path) do
      {:error, :enoent} -> {:ok, nil}
      result -> result
    end
  end

  defp editor_text?(full) do
    with true <- Path.extname(full) not in @binary_extensions,
         {:ok, %{type: :regular, size: size}} when size <= @max_text_bytes <- File.stat(full),
         {:ok, content} <- File.read(full) do
      String.valid?(content) and not String.contains?(content, <<0>>)
    else
      _not_text -> false
    end
  end

  defp diff_text?(text), do: byte_size(text) <= @max_diff_bytes and String.valid?(text)

  @impl Environment
  def list_dir(state, cwd, path), do: Environment.list_dir(state.inner, cwd, path)

  @impl Environment
  def delete_file(state, cwd, path), do: Environment.delete_file(state.inner, cwd, path)

  @impl Environment
  def run(state, command, opts), do: Environment.run(state.inner, command, opts)

  @impl Environment
  def credentials(state), do: Environment.credentials(state.inner)
end

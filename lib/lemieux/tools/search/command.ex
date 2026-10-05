defmodule Lemieux.Tools.Search.Command do
  @moduledoc """
  Runs a helper command (`rg`, `git`, `rm`) through the session's
  environment and collects what it printed.

  The search tools and `apply_patch` shell out for speed and for answers the
  environment already has (`git`'s view of what is ignored), and they do it
  through `Lemieux.Environment.run/3` rather than `System.cmd/3` because the
  environment is where the files are: a container or a sandbox runs these
  commands where the model's `bash` would, and sees the same tree.

  Output is collected up to a byte budget and then the stream is abandoned,
  which stops the command (see `Lemieux.Tool.collect_result/3`). A result
  says whether that happened, so a caller never mistakes the first megabytes
  of an answer for all of it.

  `status` is the exit status, or `:timeout`, `:truncated` or
  `{:failed, reason}` when the command did not get to exit on its own. The
  shell reports a missing program as status 127, which is how a caller tells
  "no `rg` here" from "`rg` found nothing" (status 1).
  """

  alias Lemieux.Environment

  @typedoc "What a helper command printed and how it ended."
  @type outcome :: %{
          status: non_neg_integer() | :timeout | :truncated | {:failed, term()},
          output: binary()
        }

  @doc """
  Runs `command` in `directory` through `environment`.

  Options: `:timeout_ms` (default 30 seconds) and `:max_bytes`, the output
  collected before the command is abandoned (default 4 MB).
  """
  @spec run(
          environment :: Environment.t(),
          directory :: Path.t(),
          command :: String.t(),
          opts :: keyword()
        ) :: {:ok, outcome()} | {:error, term()}
  def run(environment, directory, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 30_000)
    max_bytes = Keyword.get(opts, :max_bytes, 4_000_000)

    with {:ok, events} <-
           Environment.run(environment, command, cwd: directory, timeout_ms: timeout) do
      {:ok, collect(events, max_bytes)}
    end
  end

  @doc """
  Quotes `argument` for a POSIX shell.

  Single quotes make everything literal except a single quote, which closes
  the string, is escaped, and reopens it. A model's search pattern reaches a
  shell here, so this is the whole of the injection defence and it has to be
  total: no argument is ever interpolated any other way.
  """
  @spec quote_argument(argument :: String.t()) :: String.t()
  def quote_argument(argument) when is_binary(argument),
    do: "'" <> String.replace(argument, "'", "'\\''") <> "'"

  @doc "Joins a program and its arguments into one shell command, quoting each."
  @spec join(arguments :: [String.t()]) :: String.t()
  def join(arguments) when is_list(arguments),
    do: Enum.map_join(arguments, " ", &quote_argument/1)

  defp collect(events, max_bytes) do
    {chunks, _size, status} =
      Enum.reduce_while(events, {[], 0, nil}, &collect_event(&1, &2, max_bytes))

    %{
      status: status || {:failed, :no_exit_status},
      output: chunks |> Enum.reverse() |> IO.iodata_to_binary()
    }
  end

  defp collect_event({:data, bytes}, {chunks, size, nil}, max_bytes) do
    size = size + byte_size(bytes)

    if size > max_bytes,
      do: {:halt, {[bytes | chunks], size, :truncated}},
      else: {:cont, {[bytes | chunks], size, nil}}
  end

  defp collect_event({:exit_status, status}, {chunks, size, nil}, _max_bytes),
    do: {:halt, {chunks, size, status}}

  defp collect_event({:timeout, _timeout_ms}, {chunks, size, nil}, _max_bytes),
    do: {:halt, {chunks, size, :timeout}}

  defp collect_event({:output_limit, _bytes}, {chunks, size, nil}, _max_bytes),
    do: {:halt, {chunks, size, :truncated}}

  defp collect_event({:failed, reason}, {chunks, size, nil}, _max_bytes),
    do: {:halt, {chunks, size, {:failed, reason}}}
end

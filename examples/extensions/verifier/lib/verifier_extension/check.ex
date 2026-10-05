defmodule VerifierExtension.Check do
  @moduledoc """
  Runs the verification command with a deadline and an output cap.

  The command goes through `Lemieux.Environment`, the same boundary the
  session's `bash` tool uses, so a host that relocates tool execution into a
  container or a remote workspace gets its check run there too. Running it on
  the BEAM's own machine instead would verify a workspace the agent never
  touched whenever the environment is not local.

  Every ending is named, following the environment contract: `passed` and
  `failed` come from an exit status, `timed_out` from the deadline,
  `output_limit` from the environment's own cap, and `failed_to_run` when the
  command could not be run to completion at all. The last one is kept apart
  from `failed` on purpose. A retry prompt that says "your check exited 1"
  when the pipe broke sends the model debugging the wrong thing.

  Output is bounded by keeping the head and the tail. Test runners put the
  summary and the failing assertions at the end, and the first lines say
  which suite ran; the middle is the part nobody reads.

  The deadline is owned here, not only delegated to the environment. The
  command stream is consumed by a pump task while this process counts the
  time, and once `timeout_ms` plus a short teardown grace has passed the
  check is reported as timed out whether or not the environment has finished
  stopping the command. Without that, a suite whose grandchild kept the
  output pipe open outlived its deadline on a host without `setsid`: the
  environment killed the shell, the orphan held the pipe, and the "bounded"
  check lasted as long as the orphan did. The orphan is the environment's
  problem either way; the pipeline moving on is this module's.
  """

  alias Lemieux.Environment

  @default_timeout_ms 120_000
  @default_output_bytes 16_384
  @default_excerpt_bytes 4_096
  # How long past its own deadline the environment gets to say `{:timeout, _}`
  # itself before this module stops waiting for it.
  @teardown_grace_ms 1_000

  @typedoc "A completed check, ready for the observation and the retry prompt."
  @type result :: %{required(String.t()) => term()}

  @doc """
  Runs `command` in `cwd` and returns a JSON-shaped result.

  Options: `:timeout_ms` (default #{@default_timeout_ms}), `:max_output_bytes`
  (default #{@default_output_bytes}) and `:environment` (a
  `t:Lemieux.Environment.t/0`; default the local environment).
  """
  @spec run(command :: String.t(), cwd :: Path.t(), opts :: keyword()) :: result()
  def run(command, cwd, opts \\ []) when is_binary(command) and is_binary(cwd) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    cap = Keyword.get(opts, :max_output_bytes, @default_output_bytes)
    environment = Keyword.get(opts, :environment, Environment.local())
    started = System.monotonic_time(:millisecond)

    result =
      case Environment.run(environment, command, cwd: cwd, timeout_ms: timeout) do
        {:ok, events} -> collect(events, cap, started + timeout + @teardown_grace_ms)
        {:error, reason} -> failed_to_run(reason, buffer())
      end

    Map.merge(result, %{
      "command" => command,
      "timeout_ms" => timeout,
      "duration_ms" => System.monotonic_time(:millisecond) - started
    })
  end

  @doc """
  The last `bytes` of `output`, starting on a line boundary, for a prompt.

  The retry prompt carries what the model needs to act on and no more; the
  full bounded output stays in the observation for whoever reads the report.
  """
  @spec excerpt(output :: String.t(), bytes :: pos_integer()) :: String.t()
  def excerpt(output, bytes \\ @default_excerpt_bytes)
      when is_binary(output) and is_integer(bytes) and bytes > 0 do
    if byte_size(output) <= bytes do
      output
    else
      tail = binary_part(output, byte_size(output) - bytes, bytes)

      tail =
        case String.split(tail, "\n", parts: 2) do
          [_partial, rest] -> rest
          [whole] -> whole
        end

      "... [#{byte_size(output) - byte_size(tail)} bytes omitted] ...\n" <> sanitize(tail)
    end
  end

  # The pump forwards every event as a message so the deadline can be kept
  # here with `receive ... after`, which a blocking enumeration of the stream
  # could not offer. Killing the pump is what ends a stream that has outlived
  # its deadline: the environment monitors its consumer and tears down.
  defp collect(events, cap, deadline) do
    parent = self()
    ref = make_ref()

    pump =
      Task.async(fn ->
        Enum.each(events, &send(parent, {ref, &1}))
        send(parent, {ref, :done})
      end)

    result = receive_events(ref, cap, deadline, buffer())
    Task.shutdown(pump, :brutal_kill)
    result
  end

  defp receive_events(ref, cap, deadline, buffer) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, {:data, data}} -> receive_events(ref, cap, deadline, keep(buffer, data, cap))
      {^ref, {:exit_status, status}} -> exited(status, buffer)
      {^ref, {:timeout, _ms}} -> finish("timed_out", buffer)
      {^ref, {:output_limit, _bytes}} -> finish("output_limit", buffer)
      {^ref, {:failed, reason}} -> failed_to_run(reason, buffer)
      {^ref, :done} -> failed_to_run(:no_terminal_event, buffer)
    after
      remaining -> finish("timed_out", buffer)
    end
  end

  defp exited(0, buffer), do: finish("passed", buffer) |> Map.put("exit_status", 0)
  defp exited(status, buffer), do: finish("failed", buffer) |> Map.put("exit_status", status)

  defp failed_to_run(reason, buffer),
    do: finish("failed_to_run", buffer) |> Map.put("error", inspect(reason))

  defp finish(status, buffer),
    do: %{"status" => status, "exit_status" => nil, "output" => output(buffer)}

  defp buffer, do: %{head: "", tail: "", omitted: 0}

  # The head fills first, up to half the cap; everything after that rolls
  # through a tail of the other half, so the record always ends with the
  # command's last words.
  defp keep(buffer, data, cap) do
    half = div(cap, 2)
    room = max(half - byte_size(buffer.head), 0)

    {to_head, rest} =
      if byte_size(data) <= room,
        do: {data, ""},
        else: {binary_part(data, 0, room), binary_part(data, room, byte_size(data) - room)}

    %{buffer | head: buffer.head <> to_head}
    |> keep_tail(rest, half)
  end

  defp keep_tail(buffer, "", _half), do: buffer

  defp keep_tail(buffer, data, half) do
    joined = buffer.tail <> data
    excess = max(byte_size(joined) - half, 0)

    %{
      buffer
      | tail: binary_part(joined, excess, byte_size(joined) - excess),
        omitted: buffer.omitted + excess
    }
  end

  defp output(%{omitted: 0} = buffer), do: sanitize(buffer.head <> buffer.tail)

  defp output(buffer) do
    sanitize(buffer.head <> "\n... [#{buffer.omitted} bytes omitted] ...\n" <> buffer.tail)
  end

  # Byte caps cut through multi-byte characters and test runners print
  # whatever the code under test printed. The record has to survive JSON
  # encoding either way.
  defp sanitize(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> String.chunk(:valid)
      |> Enum.map_join(&if(String.valid?(&1), do: &1, else: "�"))
    end
  end
end

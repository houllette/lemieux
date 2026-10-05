defmodule Lemieux.Benchmark.Command do
  @moduledoc false

  @default_timeout :timer.minutes(10)
  @default_output 1_000_000

  @spec run([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(argv, opts \\ [])

  def run([program | args] = argv, opts)
      when is_binary(program) and is_list(args) and is_list(opts) do
    with {:ok, executable} <- executable(program),
         :ok <- valid_args(args) do
      started = System.monotonic_time(:millisecond)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          port_options(args, opts)
        )

      outcome = collect(port, Keyword.get(opts, :timeout, @default_timeout), opts)
      duration = System.monotonic_time(:millisecond) - started

      {:ok,
       outcome
       |> Map.put("command", argv)
       |> Map.put("duration_ms", duration)}
    end
  end

  def run(_argv, _opts), do: {:error, :invalid_command}

  defp executable(program) do
    case System.find_executable(program) do
      nil -> {:error, {:executable_not_found, program}}
      path -> {:ok, path}
    end
  end

  defp valid_args(args) do
    if Enum.all?(args, &is_binary/1), do: :ok, else: {:error, :invalid_arguments}
  end

  defp port_options(args, opts) do
    options = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: Enum.map(args, &String.to_charlist/1),
      env: env(Keyword.get(opts, :env, %{}))
    ]

    case Keyword.get(opts, :cwd) do
      nil -> options
      cwd -> [{:cd, String.to_charlist(cwd)} | options]
    end
  end

  defp env(env) when is_map(env), do: env |> Map.to_list() |> env()

  defp env(env) when is_list(env) do
    Enum.map(env, fn {key, value} ->
      {key |> to_string() |> String.to_charlist(), value |> to_string() |> String.to_charlist()}
    end)
  end

  defp collect(port, timeout, opts) do
    deadline = System.monotonic_time(:millisecond) + timeout
    limit = Keyword.get(opts, :max_output_bytes, @default_output)
    receive_port(port, deadline, limit, [], 0, 0)
  end

  defp receive_port(port, deadline, limit, chunks, kept, omitted) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        {chunk, chunk_omitted} = keep(data, max(limit - kept, 0))

        receive_port(
          port,
          deadline,
          limit,
          [chunk | chunks],
          kept + byte_size(chunk),
          omitted + chunk_omitted
        )

      {^port, {:exit_status, status}} ->
        %{
          "output" => output(chunks, omitted),
          "exit_status" => status,
          "timed_out" => false
        }
    after
      remaining ->
        close(port)

        %{
          "output" => output(chunks, omitted),
          "exit_status" => nil,
          "timed_out" => true
        }
    end
  end

  defp keep(data, remaining) when byte_size(data) <= remaining, do: {data, 0}

  defp keep(data, remaining) do
    {binary_part(data, 0, remaining), byte_size(data) - remaining}
  end

  defp output(chunks, 0), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp output(chunks, omitted) do
    output(chunks, 0) <> "\n\n... [#{omitted} more bytes omitted] ..."
  end

  defp close(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end
end

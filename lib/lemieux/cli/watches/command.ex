defmodule Lemieux.CLI.Watches.Command do
  @moduledoc """
  A personal-config status reader for deployments and other external jobs.

  The person configures a fixed command, never the model. The inert target is
  passed as `LMX_WATCH_TARGET` JSON, without shell interpolation. The command
  must only observe an existing activity and print one bounded JSON object:
  `state` is `pending`, `done`, `retry` or `error`; `summary` describes it.
  Done adds `outcome`, `logs` and `url`; retry adds `retry_after_ms`; error
  adds `category` (`authentication`, `unavailable` or `failed`). Source
  identity remains in the stored target even if the reader omits it.
  """
  @behaviour Lemieux.Extensions.Watches.Source
  alias Lemieux.Environment
  alias Lemieux.Extensions.Watches.Record

  @impl true
  def validate(_state, %{"run_id" => id} = target)
      when is_binary(id) and byte_size(id) in 1..200 do
    with :ok <- Record.validate_target(target), do: {:ok, target}
  end

  def validate(_state, _target), do: {:error, :target_needs_run_id}

  @impl true
  def observe(state, target) do
    with {:ok, stream} <-
           Environment.run(state.environment, state.command,
             cwd: state.cwd,
             env: [{"LMX_WATCH_TARGET", JSON.encode!(target)}],
             timeout_ms: 10_000,
             max_output_bytes: 32_768
           ),
         {:ok, json} <- collect(stream),
         {:ok, result} when is_map(result) <- JSON.decode(json) do
      observation(result)
    else
      _failure ->
        {:error, :unavailable,
         "Status reader failed, timed out, exceeded its output bound or returned invalid JSON."}
    end
  end

  defp collect(stream) do
    {chunks, success?} =
      Enum.reduce(stream, {[], false}, fn
        {:data, bytes}, {chunks, success?} -> {[bytes | chunks], success?}
        {:exit_status, 0}, {chunks, _old} -> {chunks, true}
        _failure, {chunks, _old} -> {chunks, false}
      end)

    if success?,
      do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()},
      else: {:error, :reader_failed}
  end

  defp observation(%{"state" => "pending"} = result),
    do: {:pending, result["summary"] || "Running"}

  defp observation(%{"state" => "done"} = result), do: {:done, result}

  defp observation(%{"state" => "retry", "retry_after_ms" => delay} = result)
       when is_integer(delay) and delay > 0,
       do: {:retry, delay, result["summary"] || "Status rate limited"}

  defp observation(%{"state" => "error", "category" => category} = result) do
    case category do
      "authentication" -> {:error, :authentication, result["summary"] || "Authentication failed"}
      "failed" -> {:error, :failed, result["summary"] || "Status failed"}
      _other -> {:error, :unavailable, result["summary"] || "Status unavailable"}
    end
  end

  defp observation(_result),
    do: {:error, :unavailable, "Status reader returned an unknown state."}
end

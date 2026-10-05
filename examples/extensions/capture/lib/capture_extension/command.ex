defmodule CaptureExtension.Command do
  @moduledoc """
  The `sessionEnd` command-hook entry point, for a prebuilt `lmx`.

  `bin/capture` runs `main/0` under `mix run` with the hook's JSON on stdin.
  The command protocol (`docs/hooks.md`) parses stdout as JSON and surfaces
  stderr only when a hook fails, so this variant has no channel for the line
  a person would read: it goes to stderr, where a debugging operator finds
  it, and is appended to `capture.log` beside the drafts, where anyone can.
  Stdout gets a small JSON object naming the draft, or `{}` when there was
  nothing to draft — including for events other than `sessionEnd`, which a
  hook file may route here by mistake.

  The exit status is always `0`. A failure to draft is reported on stderr
  and must not read as a policy decision; there is nothing to block.
  """

  alias CaptureExtension.Config
  alias CaptureExtension.Draft

  @doc "Reads the hook input on stdin and writes the protocol's JSON reply on stdout."
  @spec main() :: :ok
  def main do
    case run(IO.read(:stdio, :eof), System.get_env()) do
      {:ok, output} ->
        IO.puts(JSON.encode!(output))

      {:error, message} ->
        IO.puts(:stderr, "capture: #{message}")
        IO.puts("{}")
    end
  end

  @doc """
  Handles one hook input against an environment, returning the JSON reply.

  Both are parameters so a test can describe a hook call without owning the
  process's stdin or environment. `Config.from_env/1` names the variables.
  """
  @spec run(
          input :: String.t() | :eof | {:error, term()},
          env :: %{optional(String.t()) => String.t()}
        ) ::
          {:ok, map()} | {:error, String.t()}
  def run(input, env) when is_binary(input) and is_map(env) do
    with {:ok, event} <- decode(input),
         {:ok, config} <- Config.from_env(env) do
      handle(event, config)
    end
  end

  def run(:eof, _env), do: {:error, "no hook input on stdin"}
  def run({:error, reason}, _env), do: {:error, "could not read stdin: #{inspect(reason)}"}

  defp decode(input) do
    case JSON.decode(input) do
      {:ok, event} when is_map(event) -> {:ok, event}
      _invalid -> {:error, "hook input is not a JSON object"}
    end
  end

  defp handle(%{"hook_event_name" => "sessionEnd", "session_id" => id, "cwd" => cwd}, config)
       when is_binary(id) and is_binary(cwd) do
    case CaptureExtension.capture(id, cwd, config) do
      {:ok, nil} ->
        {:ok, %{}}

      {:ok, %Draft{} = draft} ->
        log(draft, cwd, config)
        {:ok, output(draft)}

      {:error, reason} ->
        {:error, "session #{id} was not drafted: #{inspect(reason)}"}
    end
  end

  defp handle(%{"hook_event_name" => event}, _config) when is_binary(event), do: {:ok, %{}}

  defp handle(_event, _config),
    do: {:error, "hook input needs hook_event_name, session_id and cwd"}

  defp output(%Draft{} = draft) do
    %{
      "draft" => draft.path,
      "feedback_id" => draft.feedback_id,
      "class" => Atom.to_string(draft.class),
      "promote" => draft.promote
    }
  end

  defp log(%Draft{line: line}, cwd, config) do
    IO.puts(:stderr, line)

    config.drafts_dir
    |> Path.expand(cwd)
    |> Path.join("capture.log")
    |> File.write(line <> "\n", [:append])
    |> case do
      :ok -> :ok
      {:error, reason} -> IO.puts(:stderr, "capture: could not append capture.log: #{reason}")
    end
  end
end

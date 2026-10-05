if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.WriteDiff do
    @moduledoc """
    What `write` replaced, so an overwrite is drawn as the change it was.

    `write`'s arguments carry the new contents only; what the file held
    before is gone by the time the result arrives. When checkpoints are on
    (`Lemieux.Extensions.Checkpoints`, which `lmx` enables), the call left a
    pre-image in the checkpoint store before it ran, keyed by its call id —
    so the screen reads it back, in a task, and replaces the call's rows
    with a diff from it. Without a store the rows stay as `Overwrote PATH`
    and the new contents, which is true and says less; never `-0`, which
    was the old rows' claim about a file that had just lost every line.
    """

    alias Lemieux.Checkpoint.Store
    alias Lemieux.TUI
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.ToolText
    alias Lemieux.TUI.Transcript

    @doc """
    Starts reading the pre-image of an overwrite, when checkpoints are on.
    The answer arrives as `{:write_preimage, id, path, content, previous}`.
    """
    @spec request(TUI.t(), String.t(), map(), map()) :: TUI.t()
    def request(
          %TUI{tool_choices: %{checkpoints: dir}, id: session_id} = state,
          id,
          call,
          payload
        )
        when is_binary(dir) and is_binary(session_id) do
      with "write" <- call_name(call),
           "overwrote" <> _rest <- output(payload),
           %{"path" => path, "content" => content} when is_binary(content) <- arguments(call) do
        app = self()
        Task.start(fn -> reply(app, dir, session_id, id, path, content) end)
      end

      state
    end

    def request(state, _id, _call, _payload), do: state

    defp reply(app, dir, session_id, id, path, content) do
      case previous(dir, session_id, id) do
        {:ok, previous} -> send(app, {:write_preimage, id, path, content, previous})
        :none -> :ok
      end
    end

    @doc false
    @spec replace(TUI.t(), String.t(), String.t(), String.t(), String.t()) :: TUI.t()
    def replace(state, id, path, content, previous) do
      rows = ToolText.diff_write_rows(id, path, previous, content, Screen.theme(state))
      kept = Enum.reject(state.lines, &(ToolText.call_id(&1) == id))

      %{state | lines: kept, selection: nil, terminal: %{state.terminal | row_cache: nil}}
      |> Transcript.append_rows(rows)
    end

    @doc """
    The contents a checkpointed call found before it ran, from the newest
    turn that captured it. `:none` for a file the call created, one too large
    to have been saved, or a store without the call.
    """
    @spec previous(Path.t(), String.t(), String.t()) :: {:ok, String.t()} | :none
    def previous(dir, session_id, call_id) do
      with {:ok, session} <- Store.session_dir(dir, session_id),
           %{"before" => %{"state" => "file", "sha256" => digest}} <- capture(session, call_id),
           {:ok, contents} <- Store.blob(session, digest) do
        {:ok, contents}
      else
        _none -> :none
      end
    end

    defp capture(session, call_id) do
      session
      |> Store.turns()
      |> Enum.sort(:desc)
      |> Enum.find_value(fn turn ->
        [Store.turn_dir(session, turn), "captures"]
        |> Path.join()
        |> Store.all_json()
        |> Enum.find(&(&1["call_id"] == call_id))
      end)
    end

    defp call_name(call), do: Map.get(call, :name) || Map.get(call, "name")
    defp arguments(call), do: Map.get(call, :arguments) || Map.get(call, "arguments") || %{}
    defp output(%{"output" => output}) when is_binary(output), do: output
    defp output(_payload), do: ""
  end
end

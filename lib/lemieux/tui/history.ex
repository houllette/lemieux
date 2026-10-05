# The `history` field: what was typed before, where the arrow keys are in it,
# and the messages staged to send after the turn in flight.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.History do
    @moduledoc "Browses a `Lemieux.TUI`'s input history and edits its staged-message queue."

    alias Lemieux.TUI
    alias Lemieux.TUI.Composer
    alias Lemieux.TUI.Editor
    alias Lemieux.TUI.Flash

    @history_limit 50

    # What the history file keeps across sittings and repositories. Enough
    # to find last week's long prompt with Ctrl-R; small enough to read in
    # full when a screen opens.
    @global_limit 1_000

    @typep reply :: {:noreply, TUI.t()}

    @typedoc "A question a sitting can open with, which the staged queue waits for."
    @type question :: :trust | :first_run

    @doc false
    @spec limit() :: pos_integer()
    def limit, do: @history_limit

    @doc false
    @spec remember(history :: [String.t()], typed :: String.t()) :: [String.t()]
    def remember(history, typed) do
      if String.trim(typed) == "", do: history, else: Enum.take([typed | history], @history_limit)
    end

    @doc """
    An empty history, carrying what the history file holds.

    `file` is where every sitting's inputs are appended, newest last, one
    JSON object per line so a multi-line prompt stays one entry. `nil` keeps
    history to the session's own transcript, which is what a library host
    gets unless it names a file; `lmx` names `~/.lmx/history.jsonl`. Read
    once, here, when the screen is built: after that the list in memory is
    the one searched, and only appends touch the disk.
    """
    @spec loaded(file :: Path.t() | nil) :: TUI.history()
    def loaded(file) do
      %{
        entries: [],
        index: nil,
        draft: nil,
        queued: [],
        queued_selected: 1,
        revising: nil,
        revising_original: nil,
        file: file,
        global: read_global(file)
      }
    end

    @doc """
    Records what was just sent: in the session's up-arrow list, in the
    cross-session list Ctrl-R searches, and at the end of the history file.

    The file is written by a task, because a disk that stalls must not stall
    the key that sent the prompt. It is created private — a prompt can hold a
    pasted secret — and cut back to the newest `#{@global_limit}` entries
    once it has grown to twice that.
    """
    @spec record(history :: TUI.history(), typed :: String.t()) :: TUI.history()
    def record(history, typed) do
      history = %{history | entries: remember(history.entries, typed)}

      if String.trim(typed) == "" do
        history
      else
        persist(Map.get(history, :file), typed)

        global =
          Enum.take([typed | List.delete(Map.get(history, :global, []), typed)], @global_limit)

        Map.put(history, :global, global)
      end
    end

    defp persist(nil, _typed), do: :ok
    defp persist(file, typed), do: Task.start(fn -> append_global(file, typed) end)

    @doc """
    What Ctrl-R finds for `query`: every remembered input containing it,
    ignoring case, newest first, the session's own before other sittings'.
    """
    @spec search(history :: TUI.history(), query :: String.t()) :: [String.t()]
    def search(history, query) do
      needle = String.downcase(query)

      (history.entries ++ Map.get(history, :global, []))
      |> Enum.uniq()
      |> Enum.filter(&String.contains?(String.downcase(&1), needle))
    end

    defp read_global(nil), do: []

    defp read_global(file) do
      case File.read(file) do
        {:ok, contents} ->
          contents
          |> String.split("\n", trim: true)
          |> Enum.flat_map(&decoded/1)
          |> Enum.reverse()
          |> Enum.uniq()
          |> Enum.take(@global_limit)

        {:error, _reason} ->
          []
      end
    end

    # A line that is not what this module wrote is skipped rather than
    # failing the screen: the file is the person's, and a hand edit or a
    # torn last line costs that entry, not their history.
    defp decoded(line) do
      case JSON.decode(line) do
        {:ok, %{"text" => text}} when is_binary(text) -> [text]
        _other -> []
      end
    end

    @doc false
    @spec append_global(file :: Path.t(), typed :: String.t()) :: :ok | {:error, term()}
    def append_global(file, typed) do
      line = JSON.encode!(%{"text" => typed, "at" => DateTime.to_iso8601(DateTime.utc_now())})

      with :ok <- File.mkdir_p(Path.dirname(file)),
           :ok <- private(file),
           :ok <- File.write(file, [line, ?\n], [:append]) do
        trim(file)
      end
    end

    defp private(file) do
      if File.exists?(file) do
        :ok
      else
        with :ok <- File.write(file, "", [:exclusive]), do: File.chmod(file, 0o600)
      end
    catch
      _kind, _reason -> :ok
    end

    defp trim(file) do
      with {:ok, contents} <- File.read(file),
           lines = String.split(contents, "\n", trim: true),
           true <- length(lines) > 2 * @global_limit do
        kept = lines |> Enum.take(-@global_limit) |> Enum.map(&[&1, ?\n])
        temporary = file <> ".#{System.unique_integer([:positive])}"

        with :ok <- File.write(temporary, kept),
             :ok <- File.chmod(temporary, 0o600),
             do: File.rename(temporary, file)
      else
        _short_enough -> :ok
      end
    end

    # Stepping back into history keeps the draft; leaving it drops the draft
    # with the position, because a draft with nothing to come back to is just
    # a stale string waiting to reappear.
    @doc false
    @spec browsing(TUI.history(), non_neg_integer() | nil) :: TUI.history()
    def browsing(history, nil), do: %{history | index: nil, draft: nil}
    def browsing(history, index), do: %{history | index: index}

    # One step back (`-1`) or forward (`1`) through what was typed, or the
    # key itself when there is nowhere to step to.
    @doc false
    @spec step(ExRatatui.Event.Key.t(), TUI.t(), -1 | 1) :: reply()
    def step(_event, %TUI{history: %{index: nil}} = state, 1) do
      :ok = ExRatatui.textarea_handle_key(state.input, "end", ["ctrl"])
      {:noreply, state}
    end

    def step(event, %TUI{history: %{entries: []}} = state, _by),
      do: Composer.edit(event, state)

    def step(_event, %TUI{history: %{index: nil}} = state, -1) do
      draft = ExRatatui.textarea_get_value(state.input)
      show(%{state | history: %{state.history | draft: draft}}, 0)
    end

    def step(_event, %TUI{history: history} = state, -1),
      do: show(state, min(history.index + 1, length(history.entries) - 1))

    def step(_event, %TUI{history: %{index: 0}} = state, 1) do
      :ok = Editor.replace(state.input, state.history.draft || "")

      {:noreply,
       %{
         state
         | history: browsing(state.history, nil),
           command_menu?: true,
           command_index: 0
       }}
    end

    def step(_event, state, 1),
      do: show(state, state.history.index - 1)

    defp show(state, index) do
      :ok = Editor.replace(state.input, Enum.at(state.history.entries, index))

      {:noreply,
       %{state | history: browsing(state.history, index), command_menu?: false, command_index: 0}}
    end

    @doc false
    @spec queue_draft(TUI.t()) :: reply()
    def queue_draft(state) do
      draft = Composer.typed_value(state)

      cond do
        String.trim(draft) == "" ->
          {:noreply, Flash.show(state, "queued message cannot be empty")}

        length(state.history.queued) < 9 ->
          number = state.history.revising || length(state.history.queued) + 1
          queued = List.insert_at(state.history.queued, number - 1, draft)
          :ok = ExRatatui.textarea_set_value(state.input, "")

          {:noreply,
           state
           |> put_in([Access.key!(:history), :queued], queued)
           |> put_in([Access.key!(:history), :queued_selected], number)
           |> put_in([Access.key!(:history), :revising], nil)
           |> put_in([Access.key!(:history), :revising_original], nil)
           |> Composer.edited()}

        true ->
          {:noreply, Flash.show(state, "queue full (9) · revise or unstage a message")}
      end
    end

    @doc """
    `history` with `prompt` staged ahead of everything else: the host's
    `:prompt`, the first message of the sitting. `nil` stages nothing.

    Staged rather than kept aside, so it is what typing ahead already is —
    a numbered row above the input box while the session starts, which
    Alt+E takes back into the box and Alt+U drops — and it goes the way
    everything staged goes (`Lemieux.TUI.Submission.continue_queued/1`),
    echoed as if it had been typed.
    """
    @spec staged(history :: TUI.history(), prompt :: String.t() | nil) :: TUI.history()
    def staged(history, nil), do: history

    def staged(history, prompt) when is_binary(prompt),
      do: %{history | queued: Enum.take([prompt | history.queued], 9)}

    @doc """
    `history` with the staged queue of `from`, as it stood.

    A session's details rebuild the history from its transcript, and with it
    the queue (`Lemieux.TUI.SessionHydration`), which is right for `/new`
    and `/resume`: what was staged was for the session being left. At
    startup there was no session to leave, and the queue is what was staged
    before there was one — the host's `:prompt`, and what was typed while it
    started — so it is carried over. Before this, a draft typed and queued
    while the session started was dropped as the session came up.
    """
    @spec carry_queue(history :: TUI.history(), from :: TUI.history()) :: TUI.history()
    def carry_queue(history, from),
      do:
        Map.merge(history, Map.take(from, ~w(queued queued_selected revising revising_original)a))

    @doc """
    Holds the staged queue until `question` is answered: `:trust`, the
    question about a repository's MCP servers (`Lemieux.TUI.Trust`), or
    `:first_run`, the provider setup (`Lemieux.TUI.FirstRun`).

    What is staged when a sitting opens — the host's `:prompt`, a draft typed
    while the session started — is meant for the session those questions
    finish setting up. Sent as soon as the session was up, it would reach a
    model with no key while the provider panel was still open, and fail; or
    the session would be busy with it when the trust answer came, so the
    servers just trusted would start only with the next session
    (`Lemieux.TUI.Trust`), and the prompt would run without them. Held
    until both are answered, it runs with the provider and the servers
    chosen.

    A held message can still be revised (Alt+E) or dropped (Alt+U) like
    anything else staged, once no panel holds the keyboard.
    """
    @spec hold(state :: TUI.t(), question :: question()) :: TUI.t()
    def hold(state, question) when question in [:trust, :first_run],
      do: put_held(state, Enum.uniq([question | held_for(state.history)]))

    @doc """
    `question` was answered, or turned out to need no answer. When it was the
    last the queue was held for, and something is staged, the screen is told
    to send it (`:continue_queued`, to itself): the answers arrive where a
    reply cannot start a turn, and this keeps them from having to.

    A question nothing held for changes nothing, so answering one again —
    the trust question asked at a later start — cannot send the queue at a
    moment it was not waiting for.
    """
    @spec answered(state :: TUI.t(), question :: question()) :: TUI.t()
    def answered(state, question) do
      held = held_for(state.history)

      if question in held do
        rest = List.delete(held, question)
        if rest == [] and state.history.queued != [], do: send(self(), :continue_queued)
        put_held(state, rest)
      else
        state
      end
    end

    @doc "Whether the staged queue is waiting for an opening question. See `hold/2`."
    @spec held?(history :: TUI.history()) :: boolean()
    def held?(history), do: held_for(history) != []

    defp held_for(history), do: Map.get(history, :held_for, [])
    defp put_held(state, held), do: %{state | history: Map.put(state.history, :held_for, held)}

    @doc false
    @spec select_queued(ExRatatui.Event.Key.t(), TUI.t()) :: reply()
    def select_queued(%ExRatatui.Event.Key{code: digit}, state) do
      case Integer.parse(digit) do
        {number, ""} when number in 1..9 and number <= length(state.history.queued) ->
          {:noreply, put_in(state.history.queued_selected, number)}

        _other ->
          {:noreply, state}
      end
    end

    @doc false
    @spec revise_queued(TUI.t()) :: reply()
    def revise_queued(%{history: %{revising: number}} = state) when not is_nil(number),
      do: {:noreply, Flash.show(state, "finish editing queued ##{number} first")}

    def revise_queued(%{history: %{queued: []}} = state), do: {:noreply, state}

    def revise_queued(state) do
      if String.trim(Composer.typed_value(state)) == "" do
        selected = state.history.queued_selected
        original = Enum.at(state.history.queued, selected - 1)
        :ok = Editor.replace(state.input, original)

        {:noreply,
         state
         |> remove_queued(selected)
         |> put_in([Access.key!(:history), :revising], selected)
         |> put_in([Access.key!(:history), :revising_original], original)
         |> Composer.edited()}
      else
        {:noreply, Flash.show(state, "clear the draft before revising a queued message")}
      end
    end

    @doc false
    @spec unstage_queued(TUI.t()) :: reply()
    def unstage_queued(%{history: %{revising: number}} = state) when not is_nil(number),
      do: {:noreply, Flash.show(state, "finish editing queued ##{number} first")}

    def unstage_queued(%{history: %{queued: []}} = state), do: {:noreply, state}

    def unstage_queued(state),
      do: {:noreply, remove_queued(state, state.history.queued_selected)}

    @doc false
    @spec restore_revising(TUI.t()) :: TUI.t()
    def restore_revising(%{history: %{revising: nil}} = state), do: state

    def restore_revising(state) do
      number = state.history.revising
      queued = List.insert_at(state.history.queued, number - 1, state.history.revising_original)

      state
      |> put_in([Access.key!(:history), :queued], queued)
      |> put_in([Access.key!(:history), :queued_selected], number)
      |> put_in([Access.key!(:history), :revising], nil)
      |> put_in([Access.key!(:history), :revising_original], nil)
    end

    defp remove_queued(state, number) do
      queued = List.delete_at(state.history.queued, number - 1)

      state
      |> put_in([Access.key!(:history), :queued], queued)
      |> put_in([Access.key!(:history), :queued_selected], max(min(number, length(queued)), 1))
    end
  end
end

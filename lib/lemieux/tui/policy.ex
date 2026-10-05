if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Policy do
    @moduledoc """
    What the screen says and does about permissions and the sandbox, and
    the other limits of what the agent does unasked that a sitting starts
    with.

    `Lemieux.Extensions.Permissions` decides which calls wait for a person;
    this is the person's side of it. It is off unless the host passed a
    handle (`:permissions`), and the screen says so plainly at startup —
    every tool call running unasked is a fact about the sitting, not a
    detail for the documentation.

      * The banner, in the notice box at startup, names the mode and the
        sandbox, and — where checkpoints are on but what commands change is
        not recorded, outside a git repository — that `/undo` takes back
        file-tool edits only there.
      * Shift-Tab steps the mode (`Permissions.cycle/1`, which never lands on
        full auto: that is a choice made in configuration, not by a key held
        a moment too long).
      * The approval card lists the extension's suggestions, and `a` (or
        `a2`, `a3`…) takes one: the rule is remembered for the repository, or
        the mode changes, and the waiting call runs.
    """

    alias Lemieux.Conversation
    alias Lemieux.Conversation.Doctor
    alias Lemieux.Extensions.Permissions
    alias Lemieux.Session
    alias Lemieux.TUI
    alias Lemieux.TUI.Flash
    alias Lemieux.TUI.Notices
    alias Lemieux.TUI.Transcript

    @doc "The current mode's label, or `nil` when permissions are off."
    @spec label(TUI.t()) :: String.t() | nil
    def label(%TUI{tool_choices: %{permissions: nil}}), do: nil

    def label(%TUI{tool_choices: %{permissions: handle}}),
      do: Permissions.label(Permissions.mode(handle))

    @doc false
    @spec cycle(TUI.t()) :: TUI.t()
    def cycle(%TUI{tool_choices: %{permissions: nil}} = state),
      do:
        Flash.show(
          state,
          "permissions are off: tools run without asking · " <>
            "start lmx with --permission-mode ask to be asked first"
        )

    def cycle(%TUI{tool_choices: %{permissions: handle}} = state) do
      mode = Permissions.cycle(handle)
      Flash.show(state, "permission mode: #{Permissions.label(mode)}")
    end

    @doc """
    The startup notices, in the notice box (`Lemieux.TUI.Notices`): what runs
    without asking and where, then, where checkpoints are on and what
    commands change is not recorded, that `/undo` covers file-tool edits
    only here (`Lemieux.Conversation.Doctor.undo_notice/1`).

    `Lemieux.TUI.Lifecycle` calls this once per sitting, as the session
    becomes the screen's and before the first-run panel opens, so it is also
    where the conversation learns that the session starts on a model nobody
    chose (`Lemieux.Conversation.unchosen/1`): the one moment the screen holds
    both the host's first-run setup and the conversation that will word the
    first prompt's missing-key error.
    """
    @spec banner(state :: TUI.t()) :: TUI.t()
    def banner(state) do
      state
      |> mode_banner()
      |> undo_scope()
      |> unchosen_model()
    end

    defp mode_banner(%TUI{session_view: %{banner?: false}} = state), do: state

    defp mode_banner(state) do
      mode =
        case label(state) do
          nil -> "full auto: tools run without asking"
          label -> "permission mode: #{label} (Shift-Tab changes it)"
        end

      Notices.say(state, :info, mode <> " · " <> sandbox(state.session_view.sandbox))
    end

    # Said once, at the start: outside a git repository `/undo` takes back
    # what the file tools changed and nothing a command did, and a person
    # letting tools run unasked should hear that before the first `rm`, not
    # from the first `/undo` after it. Asked only where the host records
    # checkpoints, which is taken to mean commands as well, as `lmx` records
    # them (`git: true`): whether a host does is in the session's harness
    # record, which only a copy of its transcript brings, and `/doctor` is
    # where that is paid for. `git` runs here, once per sitting, bounded
    # (`Lemieux.Conversation.Doctor.undo_coverage/2`).
    defp undo_scope(%TUI{tool_choices: %{checkpoints: dir}, references: %{cwd: cwd}} = state)
         when is_binary(dir) and is_binary(cwd) do
      case Doctor.undo_notice(cwd) do
        nil -> state
        notice -> Notices.say(state, :info, notice)
      end
    end

    defp undo_scope(state), do: state

    # A first-run panel opened with no provider selected, no row whose key is
    # already set, and no conversation yet: the session starts on the host's
    # placeholder, which nobody chose and nothing has a key for. Where a
    # row's key is set (`--config none` starts on the placeholder beside a
    # key it does not look at), the placeholder's own provider and
    # `/provider` are the way out, and the missing-key line keeps naming them.
    #
    # A resumed session (`lmx --resume ID`, `lmx -c`) runs on its
    # transcript's model, and the line names that vendor, as a `/resume`
    # inside the sitting does (`Lemieux.TUI.SessionHydration`). The setup
    # cannot tell one from a placeholder: `Lemieux.CLI.Models.first_run/2`
    # reads what chose the start model before the transcript replaced it, a
    # guess, so `:selected` is nil there too, and an xai session resumed
    # without its key was told to set ANTHROPIC_API_KEY or OPENAI_API_KEY and
    # start again — which resumed it into the same refusal. The prompts the
    # transcript holds, which hydration has just put on up-arrow, tell them
    # apart.
    defp unchosen_model(
           %TUI{
             session_view: %{first_run: %{providers: rows} = setup},
             history: %{entries: []}
           } = state
         )
         when is_list(rows) do
      if setup[:selected] == nil and not Enum.any?(rows, &(Map.get(&1, :credential) == :present)),
        do: %{state | conversation: Conversation.unchosen(state.conversation)},
        else: state
    end

    defp unchosen_model(state), do: state

    defp sandbox(nil), do: "commands are not sandboxed"

    defp sandbox(%{"backend" => backend} = description) do
      network = if description["network"], do: "network allowed", else: "no network"
      "commands sandboxed (#{backend}, #{network})"
    end

    @doc """
    The rows an approval card adds for the extension's reasoning and
    suggestions, under the call's own card. Empty for a call parked by
    anything else.
    """
    @spec card_rows(String.t(), map() | nil) :: [TUI.line()]
    def card_rows(_id, nil), do: []

    def card_rows(id, permission) when is_map(permission) do
      reason =
        case {permission["mode"], permission["reason"]} do
          {nil, nil} -> []
          {mode, nil} -> [{:tool_detail, id, :ordinary, "#{mode} mode"}]
          {nil, reason} -> [{:tool_detail, id, :ordinary, reason}]
          {mode, reason} -> [{:tool_detail, id, :ordinary, "#{mode} mode · #{reason}"}]
        end

      suggestions =
        permission
        |> Map.get("suggestions", [])
        |> Enum.with_index(1)
        |> Enum.map(fn {suggestion, index} ->
          key = if index == 1, do: "a", else: "a#{index}"
          {:tool_detail, id, :ordinary, "#{key} · #{suggestion["label"]}"}
        end)

      reason ++ suggestions
    end

    @doc """
    Whether `typed` takes one of the suggestions on the oldest waiting card:
    `a`, `a2`, `always`. Returns the suggestion's position.
    """
    @spec always(String.t()) :: {:ok, pos_integer()} | :error
    def always(typed) do
      case Regex.run(~r/^\s*(?:a|always)\s*(\d*)\s*$/i, typed) do
        [_all, ""] -> {:ok, 1}
        [_all, digits] -> {:ok, String.to_integer(digits)}
        nil -> :error
      end
    end

    @doc """
    Takes suggestion `index` for the oldest waiting call: remembers the rule
    or changes the mode, then lets the call run. Says why when it cannot.
    """
    @spec take(TUI.t(), pos_integer()) :: TUI.t()
    def take(%TUI{tool_choices: %{permissions: nil}} = state, _index),
      do: Flash.show(state, "permissions are off, so there is nothing to always allow")

    def take(%TUI{conversation: %{approvals: [%{call_id: id} | _rest]}} = state, index) do
      suggestion =
        state.tools
        |> Map.get(:permissions, %{})
        |> Map.get(id, %{})
        |> Map.get("suggestions", [])
        |> Enum.at(index - 1)

      handle = state.tool_choices.permissions

      with %{} <- suggestion,
           :ok <- apply_suggestion(handle, suggestion),
           :ok <- Session.resolve_tool(state.session, id, :allow) do
        Transcript.say(state, :lmx, "#{suggestion["label"]} · allowed")
      else
        nil -> Flash.show(state, "that call has no suggestion #{index}")
        {:error, reason} -> Flash.show(state, "could not allow it: #{inspect(reason)}")
      end
    end

    def take(state, _index), do: Flash.show(state, "no call is waiting for approval")

    defp apply_suggestion(handle, %{"rule" => rule}) when is_binary(rule),
      do: Permissions.remember(handle, rule)

    defp apply_suggestion(handle, %{"mode" => mode}) when is_binary(mode),
      do: Permissions.set_mode(handle, mode)

    defp apply_suggestion(_handle, _suggestion), do: {:error, :unknown_suggestion}
  end
end

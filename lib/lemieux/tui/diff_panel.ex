if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.DiffPanel do
    @moduledoc """
    `/diff`'s changed-file tree and a scrollable per-file patch.

    Status and patches run in supervised tasks through the session environment.
    The panel owns no filesystem operation. A token associates each reply with
    the panel that requested it; closing, refreshing or switching sessions
    makes late replies harmless. Display paths escape controls and retain the
    raw Git path separately, including renames and literal pathspec syntax.
    """
    alias ExRatatui.Event.Key
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.Conversation.Command.Diff
    alias Lemieux.TUI
    alias Lemieux.TUI.{Art, Blocks, Modal, RichText, Screen, Takeover}

    @doc false
    @spec open(state :: TUI.t()) :: TUI.t()
    def open(state) do
      token = make_ref()

      state = %{
        state
        | modal: %{
            kind: :diff,
            token: token,
            session: state.session,
            loading?: true,
            files: [],
            omitted: 0,
            tree: nil,
            selected: nil,
            preview: [],
            offset: 0,
            view: :tree,
            notice: "Reading working tree…",
            pending: nil
          }
      }

      request(state, fn environment, cwd -> {:diff_files, token, Diff.files(environment, cwd)} end)
    end

    @doc false
    @spec answer(state :: TUI.t(), message :: tuple()) :: TUI.t()
    def answer(
          %TUI{session: session, modal: %{kind: :diff, session: session, token: token}} = state,
          {:diff_files, token, {:ok, result}}
        ) do
      files =
        result.files
        |> Enum.with_index()
        |> Enum.map(fn {file, index} ->
          display = display_path(file.path)

          tree_path =
            if String.length(display) > 220,
              do: String.slice(display, 0, 200) <> "…#{index}",
              else: display

          Map.merge(file, %{
            display: display,
            tree_path: tree_path <> " [#{String.trim(file.status)}]"
          })
        end)

      paths = Enum.map(files, & &1.tree_path)
      selected = List.first(paths)

      tree =
        if paths != [],
          do:
            Art.new("file-tree", %{
              paths: paths,
              walk: false,
              root: "changes since HEAD",
              open: TUI.A2UI.folders(paths),
              cursor: selected,
              cols: 40,
              rows: max(min(state.terminal.height - 6, 100), 4)
            })

      notice = file_count(files, result.omitted)

      put_in(state.modal, %{
        state.modal
        | files: files,
          omitted: result.omitted,
          tree: tree,
          selected: selected,
          loading?: false,
          notice: notice
      })
    end

    def answer(
          %TUI{session: session, modal: %{kind: :diff, session: session, token: token}} = state,
          {:diff_files, token, {:error, reason}}
        ),
        do: put_in(state.modal, %{state.modal | loading?: false, notice: reason})

    def answer(
          %TUI{session: session, modal: %{kind: :diff, session: session, pending: token}} = state,
          {:diff_preview, token, {:ok, text}}
        ),
        do:
          put_in(state.modal, %{
            state.modal
            | preview: Blocks.rows("```diff\n" <> text <> "\n```", Screen.theme(state)),
              pending: nil
          })

    def answer(
          %TUI{session: session, modal: %{kind: :diff, session: session, pending: token}} = state,
          {:diff_preview, token, {:error, reason}}
        ),
        do: put_in(state.modal, %{state.modal | preview: [{:lmx, reason}], pending: nil})

    def answer(state, _stale), do: state

    @doc false
    @spec key(event :: Key.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def key(%Key{code: code, modifiers: []}, state) when code in ["q", "esc"],
      do: {:noreply, Modal.close(state)}

    def key(%Key{code: "r", modifiers: []}, state), do: {:noreply, open(state)}

    def key(%Key{code: code, modifiers: []}, %{modal: %{view: :preview}} = state)
        when code in ["left", "backspace", "tab"],
        do: {:noreply, put_in(state.modal.view, :tree)}

    def key(%Key{code: code, modifiers: []}, %{modal: %{view: :preview}} = state) do
      by =
        case code do
          "up" ->
            -1

          "down" ->
            1

          "page_up" ->
            -page(state)

          "page_down" ->
            page(state)

          "home" ->
            -state.modal.offset

          "end" ->
            length(
              RichText.lines(
                state.modal.preview,
                max(state.terminal.width - 4, 1),
                Screen.theme(state)
              )
            )

          _other ->
            0
        end

      rows =
        length(
          RichText.lines(
            state.modal.preview,
            max(state.terminal.width - 4, 1),
            Screen.theme(state)
          )
        )

      offset = (state.modal.offset + by) |> max(0) |> min(max(rows - page(state), 0))
      {:noreply, put_in(state.modal.offset, offset)}
    end

    def key(%Key{code: code, modifiers: []} = event, state) when code in ["enter", "tab"] do
      case Enum.find(state.modal.files, &(&1.tree_path == state.modal.selected)) do
        nil -> move(event, state)
        file -> {:noreply, preview(state, file)}
      end
    end

    def key(event, state), do: move(event, state)

    defp move(%Key{code: code, modifiers: []}, %{modal: %{tree: tree}} = state)
         when not is_nil(tree), do: move_tree(state, tree, code)

    defp move(%Key{code: code, modifiers: []}, %{modal: %{tree: nil, files: files}} = state)
         when files != [] do
      index = Enum.find_index(files, &(&1.tree_path == state.modal.selected)) || 0
      next = fallback_index(code, index, length(files), page(state))
      {:noreply, put_in(state.modal.selected, Enum.at(files, next).tree_path)}
    end

    defp move(_event, state), do: {:noreply, state}

    # In an ExRatatui-only host Art.event/2 can only return :ignore. Keep the
    # ASCII tree branch out of that build rather than compiling unreachable
    # event clauses; its nil tree uses the ordinary list navigation above.
    if Code.ensure_loaded?(Ascii.ExRatatui) do
      defp move_tree(state, tree, code) do
        case Art.event(tree, {:key, code}) do
          {:ok, tree} ->
            {:noreply,
             put_in(state.modal, %{state.modal | tree: tree, selected: tree.options.cursor})}

          :ignore ->
            {:noreply, state}
        end
      end
    else
      defp move_tree(state, _tree, _code), do: {:noreply, state}
    end

    defp fallback_index("up", index, _count, _page), do: max(index - 1, 0)
    defp fallback_index("down", index, count, _page), do: min(index + 1, count - 1)
    defp fallback_index("home", _index, _count, _page), do: 0
    defp fallback_index("end", _index, count, _page), do: count - 1
    defp fallback_index("page_up", index, _count, page), do: max(index - page, 0)
    defp fallback_index("page_down", index, count, page), do: min(index + page, count - 1)
    defp fallback_index(_code, index, _count, _page), do: index

    defp file_count([], _omitted), do: "No changes in the working tree"
    defp file_count(files, 0), do: "#{length(files)} files"
    defp file_count(files, omitted), do: "#{length(files)} files · #{omitted} omitted"

    @doc false
    @spec resize(state :: TUI.t()) :: TUI.t()
    def resize(%TUI{modal: %{kind: :diff, tree: tree}} = state) when not is_nil(tree),
      do:
        put_in(
          state.modal.tree,
          Art.update(tree, %{rows: max(min(state.terminal.height - 6, 100), 4)})
        )

    def resize(state), do: state

    defp preview(state, file) do
      token = make_ref()

      state =
        put_in(state.modal, %{
          state.modal
          | pending: token,
            view: :preview,
            offset: 0,
            preview: [{:lmx, "Reading patch for #{file.display}…"}]
        })

      request(state, fn environment, cwd ->
        {:diff_preview, token, Diff.preview(environment, cwd, file)}
      end)
    end

    defp request(state, work) do
      app = self()
      environment = state.references.environment || Lemieux.Environment.local()
      cwd = state.references.cwd || "."
      task = fn -> send(app, work.(environment, cwd)) end

      if state.resume.task_supervisor,
        do: Task.Supervisor.start_child(state.resume.task_supervisor, task),
        else: Task.start_link(task)

      state
    end

    @doc false
    @spec paste(event :: term(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def paste(_event, state), do: {:noreply, state}

    @doc false
    @spec render(state :: TUI.t(), panes :: map()) :: [{term(), Rect.t()}]
    def render(state, panes) do
      area = Takeover.area(panes, state.terminal.height)

      inner = %Rect{
        x: area.x + min(2, max(area.width - 1, 0)),
        y: area.y + min(1, max(area.height - 1, 0)),
        width: max(area.width - 4, 1),
        height: max(area.height - 3, 1)
      }

      lines =
        case state.modal.view do
          :preview ->
            RichText.lines(state.modal.preview, inner.width, Screen.theme(state))

          :tree ->
            paths = Enum.map_join(state.modal.files, "\n", & &1.display)

            Art.lines(
              state.modal.tree,
              state.modal.notice <> "\n" <> paths,
              inner.width,
              Screen.theme(state)
            )
        end

      text = %Paragraph{text: lines, wrap: false, scroll: {state.modal.offset, 0}}

      footer = %Paragraph{
        text: footer(state.modal, inner.width)
      }

      Takeover.frame(area, " /diff · #{state.modal.view} ") ++
        [
          {text, inner},
          {footer,
           %Rect{x: inner.x, y: area.y + max(area.height - 2, 0), width: inner.width, height: 1}}
        ]
    end

    defp page(state), do: max(state.terminal.height - 6, 1)

    defp footer(_modal, width) when width < 40, do: "Enter/Tab · q close"

    defp footer(%{view: :preview}, _width),
      do: "←/Tab tree · ↑↓ scroll · PgUp/PgDn page · r refresh · q close"

    defp footer(modal, _width),
      do: modal.notice <> " · ↑↓ files · Enter patch · r refresh · q close"

    defp display_path(path),
      do:
        path
        |> String.replace("\\", "\\\\")
        |> String.replace("\n", "\\n")
        |> String.replace("\t", "\\t")
        |> String.replace(~r/[\x00-\x1f\x7f]/, fn character ->
          "\\x" <> Base.encode16(character)
        end)
  end
end

if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Replies do
    @moduledoc """
    Where the answers of the screen's own tasks go.

    Reading a clipboard, listing a directory tree, recording a trust
    decision, saving a key and reading a checkpoint all run in tasks, so a
    slow disk or a slow command never holds a key press. Each answers with
    one message; `Lemieux.TUI.handle_info/2` hands every such message here,
    and this names the module that knows what it means.
    """

    alias Lemieux.TUI
    alias Lemieux.TUI.Composer
    alias Lemieux.TUI.FirstRun
    alias Lemieux.TUI.ImageAttachment
    alias Lemieux.TUI.MCPStatus
    alias Lemieux.TUI.Trust
    alias Lemieux.TUI.WriteDiff

    @doc false
    @spec handle(tuple(), TUI.t()) :: TUI.t()
    def handle({:file_index, cwd, files}, state), do: Composer.indexed(state, cwd, files)

    def handle({:mcp_resources, session, items}, state),
      do: Composer.resources_listed(state, session, items)

    def handle({:image_pasted, result}, state), do: ImageAttachment.pasted(state, result)
    def handle({:mcp_trust_check, pending}, state), do: Trust.checked(state, pending)

    def handle({:mcp_trust_result, decision, result, file}, state),
      do: Trust.result(state, decision, result, file)

    def handle({:first_run_saved, provider, result}, state),
      do: FirstRun.saved(state, provider, result)

    def handle({:session_catalog, session, tools, servers}, state),
      do: MCPStatus.catalog(state, session, tools, servers)

    def handle({:mcp_settled, session, statuses}, state),
      do: MCPStatus.settled(state, session, statuses)

    def handle({:write_preimage, id, path, content, previous}, state),
      do: WriteDiff.replace(state, id, path, content, previous)

    def handle(_message, state), do: state
  end
end

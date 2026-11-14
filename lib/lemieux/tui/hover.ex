if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Hover do
    @moduledoc """
    Capability-gated mouse-pointer intents for hosts owning a cell transport.

    A host opts in with `hover_pointer: true` and a four-tuple ExRatatui
    `:cell_session` transport with an intent writer. It consumes
    `{:mouse_pointer, :pointer | :restore}`; restore means the host's previous
    pointer, not a guessed terminal reset. The host owns teardown/suspension
    cleanup as well, including abrupt disconnection. No terminal I/O occurs
    here and no capability query can block an input callback.

    ExRatatui 0.20 exposes text-cursor styles and terminal titles but no local
    mouse-pointer API or OSC 22 capability/stack lifecycle. Local, SSH,
    distributed and unknown transports therefore remain inert. Completing
    #148 for the installed lmx requires that upstream API and a manual pointer
    check in a supporting terminal; emitting an escape alone is not proof.
    """

    alias ExRatatui.Event.Mouse
    alias Lemieux.TUI.Pointer

    @doc false
    @spec transition(reply :: tuple(), event :: term()) :: tuple()
    def transition(reply, event \\ nil)
    def transition({kind, state}, event), do: reconcile(kind, state, [], event)
    def transition({kind, state, opts}, event), do: reconcile(kind, state, opts, event)

    defp reconcile(kind, %{terminal: %{hover: %{enabled?: false}}} = state, opts, event),
      do: reply(kind, state, motion_opts(event, opts))

    defp reconcile(kind, state, opts, event) do
      previous = state.terminal.hover
      mouse = if is_struct(event, Mouse), do: event, else: previous.event
      shape = shape(kind, state, mouse)
      state = put_in(state.terminal.hover, %{previous | shape: shape, event: mouse})
      opts = motion_opts(event, opts)

      opts =
        if shape == previous.shape,
          do: opts,
          else:
            Keyword.update(
              opts,
              :intents,
              [{:mouse_pointer, shape}],
              &(&1 ++ [{:mouse_pointer, shape}])
            )

      reply(kind, state, opts)
    end

    defp shape(:stop, _state, _event), do: :restore
    defp shape(_kind, _state, nil), do: :restore
    defp shape(_kind, _state, %Mouse{kind: "drag"}), do: :restore

    defp shape(_kind, state, event) do
      if Pointer.target_at(state, event), do: :pointer, else: :restore
    end

    defp motion_opts(%Mouse{kind: "moved"}, opts), do: Keyword.put(opts, :render?, false)
    defp motion_opts(_event, opts), do: opts
    defp reply(kind, state, []), do: {kind, state}
    defp reply(kind, state, opts), do: {kind, state, opts}
  end
end

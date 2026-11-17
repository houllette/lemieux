if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Hover do
    @moduledoc """
    Mouse-pointer feedback for capable hosts.

    A local host opts in with `hover_pointer: true` after establishing that its
    terminal supports OSC 22. The CLI selects that option automatically for
    direct Ghostty/Kitty terminal identities, with `LMX_HOVER_POINTER=0` as
    its opt-out and `=1` as an explicit capability declaration for other paths.
    Transitions return ExRatatui 0.21's `pointer:` option; the runtime owns
    deduplicated writes and cleanup, independently of rendering. `:restore`
    maps to `:default`: upstream resets the arrow, without queries or stack
    restoration.
    The editor handoff suspends hover before its queued callback, so the reset
    reaches the terminal before the editor starts.

    A host opts in with `hover_pointer: true` and a four-tuple ExRatatui
    `:cell_session` transport with an intent writer. It consumes
    `{:mouse_pointer, :pointer | :restore}`; restore means the host's previous
    pointer, not a guessed terminal reset. The host owns teardown/suspension
    cleanup as well, including abrupt disconnection. No terminal I/O occurs
    here and no capability query can block an input callback.

    No capability query runs here. Without a host selecting the capability,
    and on remote or unknown transports, pointer feedback is inert. The CLI's
    terminal allowlist is host policy, outside this module. Headless local
    tests record shapes in the runtime snapshot without terminal I/O. Actual
    pointer appearance still needs a visual check in a supporting emulator.
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
          else: pointer_opts(opts, previous, shape)

      reply(kind, state, opts)
    end

    defp pointer_opts(opts, %{native?: true}, :restore),
      do: Keyword.put(opts, :pointer, :default)

    defp pointer_opts(opts, %{native?: true}, shape), do: Keyword.put(opts, :pointer, shape)

    defp pointer_opts(opts, _cell_host, shape),
      do:
        Keyword.update(
          opts,
          :intents,
          [{:mouse_pointer, shape}],
          &(&1 ++ [{:mouse_pointer, shape}])
        )

    defp shape(:stop, _state, _event), do: :restore
    defp shape(_kind, %{terminal: %{hover: %{suspended?: true}}}, _event), do: :restore
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

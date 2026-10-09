if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Boot do
    @moduledoc """
    The host's real startup milestones, separate from the durable transcript.

    A busy step remains busy until its task answers. No timers manufacture
    completion or percent estimates. Notices still own actionable warnings and
    sign-in links; the boot log never replaces them. It disappears with real
    screen readiness, without a decorative delay. Host-defined milestones
    append by id and subsequent observations replace that milestone.
    """
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.Tool.Escapes
    alias Lemieux.TUI.Art
    alias Lemieux.TUI.Screen

    @doc false
    @spec new() :: map()
    def new,
      do: %{steps: [%{id: :screen, text: "Preparing session", status: "busy"}], animation: nil}

    @doc "Records one bounded milestone received from the startup task."
    @spec observe(
            state :: Lemieux.TUI.t(),
            id :: atom() | String.t(),
            text :: String.t(),
            status :: String.t()
          ) :: Lemieux.TUI.t()
    def observe(state, id, text, status)
        when (is_atom(id) or (is_binary(id) and byte_size(id) in 1..160)) and
               status in ~w(ok warn fail busy) and is_binary(text) do
      step = %{id: id, text: clean(text), status: status}
      boot = state.terminal.boot

      steps =
        if Enum.any?(boot.steps, &(&1.id == id)),
          do: Enum.map(boot.steps, &replace_step(&1, step)),
          else: bounded(boot.steps ++ [step])

      animation =
        Art.new("boot-log", %{
          title: "lmx startup",
          steps: steps |> pending_last() |> Enum.map(&Map.take(&1, [:text, :status])),
          cols: 72,
          rows: min(length(steps) + 3, 60)
        })

      put_in(state.terminal.boot, %{steps: steps, animation: animation})
    end

    def observe(state, _id, _text, _status), do: state

    @doc false
    @spec render(state :: Lemieux.TUI.t(), area :: Rect.t()) :: [{term(), Rect.t()}]
    def render(_state, %Rect{height: 0}), do: []

    def render(state, area) do
      boot = state.terminal.boot
      description = Enum.map_join(pending_last(boot.steps), "\n", &"[#{&1.status}] #{&1.text}")

      lines =
        Art.lines(boot.animation, description, max(area.width, 1), Screen.theme(state))
        # The gallery's login cursor is not a startup milestone or an input.
        |> Enum.reject(
          &(String.trim(Enum.map_join(&1.spans, fn span -> span.content end)) == "_")
        )
        |> Art.compact()

      # Keep the newest milestone visible even when the terminal is very short.
      lines = Enum.take(lines, -area.height)
      [{%Paragraph{text: lines, wrap: false}, area}]
    end

    defp replace_step(%{id: id}, %{id: id} = step), do: step
    defp replace_step(old, _step), do: old

    # A short viewport must still show pending work beneath completed steps.
    defp pending_last(steps), do: Enum.sort_by(steps, &(&1.status == "busy"))

    # Preserve the pending handoff even if a host reports many extensions.
    defp bounded(steps) when length(steps) <= 128, do: steps

    defp bounded(steps),
      do:
        Enum.filter(steps, &(&1.id == :screen)) ++
          (steps |> Enum.reject(&(&1.id == :screen)) |> Enum.take(-127))

    defp clean(text),
      do:
        text
        |> Escapes.strip()
        |> String.replace(~r/[\x00-\x1f\x7f]/, " ")
        |> String.slice(0, 160)
  end
end

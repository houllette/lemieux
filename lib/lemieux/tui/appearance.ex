# What this screen calls the session and the colours it draws: `/name`,
# `/color`, `/theme`, and the terminal title that follows the name.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Appearance do
    @moduledoc "Performs `/name`, `/color` and `/theme` for a `Lemieux.TUI`, and keeps its title."

    alias Lemieux.ID.Shorthand
    alias Lemieux.TUI
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Theme
    alias Lemieux.TUI.Transcript

    # The colours `/color` accepts by name, in the order the menu offers them,
    # which is alphabetical for the reason every other menu is: fifteen names
    # nobody can see at once are fifteen names somebody has to scan for.
    # Atoms rather than a map of strings, so a name typed at the prompt is
    # matched against this list instead of reaching `String.to_atom/1`.
    @accents [
      :blue,
      :cyan,
      :dark_gray,
      :gray,
      :green,
      :light_blue,
      :light_cyan,
      :light_green,
      :light_magenta,
      :light_red,
      :light_yellow,
      :magenta,
      :red,
      :white,
      :yellow
    ]

    @accent_names Enum.map(@accents, &Atom.to_string/1)

    @doc false
    @spec accents() :: [String.t()]
    def accents, do: @accent_names

    @doc false
    @spec name_status(TUI.t()) :: TUI.t()
    def name_status(state) do
      derived = derived_name(state)

      case state.appearance.name do
        nil ->
          Transcript.say(state, :lmx, "name: #{derived} · type /name TEXT to relabel this screen")

        name ->
          Transcript.say(
            state,
            :lmx,
            "name: #{name} · #{derived} everywhere else · /name default gives it back"
          )
      end
    end

    # Both halves of `/name`, which differ only in what they have to warn
    # about. The caption is this screen's; the handle stays the id's.
    @doc false
    @spec rename(TUI.t(), String.t() | nil) :: TUI.t()
    def rename(state, nil) do
      state = put_in(state.appearance.name, nil)

      Transcript.say(retitle(state), :lmx, "name: #{derived_name(state)}")
    end

    def rename(state, name) do
      state = put_in(state.appearance.name, name)

      Transcript.say(
        retitle(state),
        :lmx,
        "name: #{name} · this screen only, and --resume still takes #{derived_name(state)}"
      )
    end

    @doc false
    @spec colour_status(TUI.t()) :: TUI.t()
    def colour_status(state) do
      Transcript.say(
        state,
        :lmx,
        "accent: #{accent_label(Screen.accent(state))} · #{length(@accents)} available · " <>
          "type /color COLOUR (Tab completes), or #rrggbb"
      )
    end

    @doc false
    @spec set_colour(TUI.t(), String.t()) :: TUI.t()
    def set_colour(state, "default"), do: recolour(state, nil)

    def set_colour(state, colour) do
      case parse_accent(colour) do
        {:ok, parsed} ->
          recolour(state, parsed)

        :error ->
          Transcript.say(
            state,
            :lmx,
            "#{colour} is not a colour I can draw · " <>
              "#{Enum.join(@accent_names, ", ")}, #rrggbb, or default"
          )
      end
    end

    @doc false
    @spec theme_status(TUI.t()) :: TUI.t()
    def theme_status(state) do
      Transcript.say(
        state,
        :lmx,
        "theme: #{Screen.theme(state).name}#{no_color_status(state.appearance.no_color)} · " <>
          "#{Enum.join(Theme.names(Screen.themes(state)), ", ")} · type /theme NAME (Tab completes)"
      )
    end

    # `/theme` is where somebody looks when the screen has no colour; the
    # answer says when that is the environment's doing, not the theme's.
    defp no_color_status(nil), do: ""
    defp no_color_status(:mono), do: " (NO_COLOR is set)"
    defp no_color_status(:named), do: " (NO_COLOR is set, so no colour is drawn)"

    # Rows already on screen are drawn in the new palette on the next frame;
    # a fenced block already highlighted keeps its highlighting, which
    # `Lemieux.TUI.Theme` says is the one thing a switch leaves alone.
    @doc false
    @spec set_theme(TUI.t(), String.t()) :: TUI.t()
    def set_theme(state, name) do
      case Theme.named(name, Screen.themes(state)) do
        {:ok, theme} ->
          state
          |> put_in([Access.key!(:appearance), :theme], theme)
          |> Transcript.say(:lmx, "theme: #{theme.name}")

        :error ->
          Transcript.say(
            state,
            :lmx,
            "#{name} is not a theme I know · #{Enum.join(Theme.names(Screen.themes(state)), ", ")}"
          )
      end
    end

    # Called wherever the displayed name can change — a session mounting, a
    # resume landing, `/name` — rather than from `render/2`, which runs at
    # frame rate and would be asking the terminal to retitle itself sixty
    # times a second to say the same thing.
    @doc false
    @spec retitle(TUI.t()) :: TUI.t()
    def retitle(state) do
      case title(state) do
        nil ->
          state

        title ->
          state.terminal.title.(title)

          state
      end
    end

    @doc """
    The terminal title for this screen: `lmx | NAME | DIRECTORY`, or `nil`
    before a session has a name.

    The directory for the reason the header has it (`Lemieux.TUI.Screen`):
    a tab is often all that is visible of a sitting, and two `lmx` tabs in
    two projects otherwise differed only by a hockey player's name.
    """
    @spec title(state :: TUI.t()) :: String.t() | nil
    def title(state) do
      case Screen.name(state) do
        nil -> nil
        name -> Screen.printable(Enum.join(["lmx", name | List.wrap(Screen.place(state))], " | "))
      end
    end

    # A screen nothing chose a palette for — no `:theme`, no `"theme"` in the
    # harness, no `NO_COLOR` — starts in the light one on a terminal that
    # said its background is light (`Lemieux.TUI.Background`). A registry
    # that replaced `"light"` gets its own; one that somehow lacks it keeps
    # the default.
    @doc false
    @spec detected(state :: TUI.t()) :: TUI.t()
    def detected(%TUI{appearance: %{theme: nil}, terminal: %{background: :light}} = state) do
      case Theme.named("light", Screen.themes(state)) do
        {:ok, theme} -> put_in(state.appearance.theme, theme)
        :error -> state
      end
    end

    def detected(state), do: state

    defp recolour(state, colour) do
      state = put_in(state.appearance.colour, colour)

      Transcript.say(state, :lmx, "accent: #{accent_label(Screen.accent(state))}")
    end

    # What the session is called when `/name` has not been used, which is what
    # every other interface calls it and therefore what a warning has to name.
    defp derived_name(%TUI{id: id}) when is_binary(id), do: Shorthand.of(id)
    defp derived_name(_state), do: "this session"

    defp parse_accent(colour) do
      normalised = colour |> String.trim() |> String.downcase() |> String.replace("-", "_")

      case Enum.find(@accents, &(Atom.to_string(&1) == normalised)) do
        nil -> parse_hex(normalised)
        accent -> {:ok, accent}
      end
    end

    # Six hex digits and nothing else. A three-digit form and the named CSS
    # colours would both be a colour vocabulary this module would then own;
    # `#rrggbb` is the one spelling every terminal-facing tool already takes.
    defp parse_hex("#" <> digits) when byte_size(digits) == 6 do
      case Base.decode16(digits, case: :mixed) do
        {:ok, <<red, green, blue>>} -> {:ok, {:rgb, red, green, blue}}
        :error -> :error
      end
    end

    defp parse_hex(_colour), do: :error

    defp accent_label({:rgb, red, green, blue}),
      do: "#" <> Base.encode16(<<red, green, blue>>, case: :lower)

    defp accent_label(nil), do: "default"
    defp accent_label(colour) when is_atom(colour), do: Atom.to_string(colour)
  end
end

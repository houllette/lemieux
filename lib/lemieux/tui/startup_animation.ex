defmodule Lemieux.TUI.StartupAnimation do
  @moduledoc """
  Data-only settings for the startup decoration. `false` disables it;
  otherwise the default is a Habs-coloured `marquee` saying GO HABS GO.

  A host can supply the same map as the config file. Only decorative pieces
  are allowed: settings never resolve module names, run commands or read files.
  Frames loop while startup is pending and stop as soon as the screen is ready.
  """

  @pieces ~w(marquee big-text fireworks starfield matrix-rain spinners)
  @keys ~w(piece options parts duration_ms background)
  @default %{
    "piece" => "marquee",
    "options" => %{"text" => "GO HABS GO", "speed" => 12},
    "parts" => %{
      "text" => "#FFFFFF",
      "frame" => "#FFFFFF",
      "bulb.on" => "#AF1E2D",
      "bulb.off" => "#FFFFFF"
    },
    "duration_ms" => 1100,
    "background" => "#192168"
  }

  @doc "The default decoration, independent of a terminal or optional dependency."
  @spec default() :: map()
  def default, do: @default

  @doc "Checks the bounded data envelope; the piece checks its options when opened."
  @spec valid?(settings :: term()) :: boolean()
  def valid?(nil), do: true
  def valid?(false), do: true

  def valid?(settings) when is_map(settings) do
    Enum.all?(Map.keys(settings), &(&1 in @keys)) and
      Map.get(settings, "piece", "marquee") in @pieces and
      valid_options?(Map.get(settings, "options", %{})) and
      valid_parts?(Map.get(settings, "parts", %{})) and
      (is_nil(Map.get(settings, "background")) or hex?(settings["background"])) and
      valid_duration?(Map.get(settings, "duration_ms", 1100))
  end

  def valid?(_settings), do: false

  @doc "Resolves defaults without losing an explicit disable setting."
  @spec resolve(settings :: map() | false | nil) :: map() | false
  def resolve(false), do: false
  def resolve(nil), do: @default

  def resolve(settings) do
    unless valid?(settings), do: raise(ArgumentError, "invalid startup_animation settings")

    if Map.get(settings, "piece", "marquee") == "marquee",
      do: Map.merge(@default, settings, &merge_defaults/3),
      else:
        Map.merge(
          %{"options" => %{}, "parts" => %{}, "duration_ms" => 1100, "background" => nil},
          settings
        )
  end

  defp merge_defaults(key, defaults, given) when key in ~w(options parts),
    do: Map.merge(defaults, given)

  defp merge_defaults(_key, _defaults, given), do: given

  defp valid_options?(options) when is_map(options) do
    map_size(options) <= 32 and
      Enum.all?(options, fn {key, value} -> is_binary(key) and scalar?(value) end) and
      byte_size(JSON.encode!(options)) <= 4096
  end

  defp valid_options?(_options), do: false

  defp scalar?(value) when is_binary(value),
    do: byte_size(value) <= 256 and not Regex.match?(~r/[\x00-\x1f\x7f]/, value)

  defp scalar?(value), do: is_number(value) or is_boolean(value)

  defp valid_parts?(parts) when is_map(parts),
    do:
      map_size(parts) <= 16 and
        Enum.all?(parts, fn {key, value} ->
          is_binary(key) and byte_size(key) <= 40 and hex?(value)
        end)

  defp valid_parts?(_parts), do: false
  defp valid_duration?(value), do: is_integer(value) and value in 100..5000
  defp hex?(value), do: is_binary(value) and Regex.match?(~r/^#[0-9a-fA-F]{6}$/, value)
end

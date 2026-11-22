defmodule Lemieux.Provider.Priority do
  @moduledoc "Requested service tiers and the legacy fast-mode representation."

  @type choice :: {String.t(), String.t()}
  @keys [:priority, :fast_mode]

  @doc "The explicitly requested tier, retaining `nil` for the connection's implicit default."
  @spec requested(keyword()) :: String.t() | nil
  def requested(params) do
    case Keyword.get(params, :priority) || Keyword.get(params, :fast_mode) do
      "off" -> "standard"
      selection -> selection
    end
  end

  @doc "The value expected by existing fast-mode callers."
  @spec fast_mode(keyword()) :: String.t()
  def fast_mode(params) do
    case requested(params) do
      mode when mode in ["fast", "ultrafast"] -> mode
      _other -> "off"
    end
  end

  @doc false
  @spec explicit(keyword()) :: keyword()
  def explicit(params), do: Keyword.take(params, @keys)

  @doc false
  @spec clear(keyword()) :: keyword()
  def clear(params), do: Keyword.drop(params, @keys)

  @doc false
  @spec legacy_params(keyword(), boolean()) :: keyword()
  def legacy_params(params, fast?) do
    case Keyword.pop(params, :priority) do
      {"standard", remaining} when fast? ->
        Keyword.put(remaining, :fast_mode, "off")

      {mode, remaining} when fast? and mode in ["fast", "ultrafast"] ->
        Keyword.put(remaining, :fast_mode, mode)

      {_mode, remaining} ->
        remaining
    end
  end

  @doc false
  @spec choices([choice()]) :: [choice()]
  def choices(choices) do
    for mode <- ~w(flex standard fast ultrafast),
        choice <- List.wrap(List.keyfind(choices, mode, 0) || baseline(mode)),
        do: choice
  end

  defp baseline("standard"), do: {"standard", "Use the connection's standard service"}
  defp baseline(_mode), do: nil

  @doc false
  @spec legacy_choices([String.t()]) :: [choice()]
  def legacy_choices(modes), do: Enum.map(modes, &{&1, "Request this connection's service tier"})
end

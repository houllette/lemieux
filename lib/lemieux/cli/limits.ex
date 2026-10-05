defmodule Lemieux.CLI.Limits do
  @moduledoc false

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Options

  @fields [:max_turns, :max_requests, :max_cost_usd]

  # The flag, then `LMX_MAX_TURNS`/`LMX_MAX_REQUESTS`/`LMX_MAX_COST_USD`, then
  # the config file. A blank variable counts as unset and falls through to the
  # file (`Lemieux.CLI.Options.env/1`), as every other variable `lmx` reads
  # does: `export LMX_MAX_TURNS=` or a template's unfilled line used to be
  # refused as "requires a positive integer", so every command stopped
  # before it started over a limit nobody had set.
  @spec parse(parsed :: keyword(), config :: Config.t()) ::
          {:ok, keyword()} | {:error, String.t()}
  def parse(parsed, config) do
    Enum.reduce_while(@fields, {:ok, []}, fn field, {:ok, limits} ->
      env = "LMX_" <> String.upcase(Atom.to_string(field))
      flag = "--" <> String.replace(Atom.to_string(field), "_", "-")

      value =
        Keyword.get(parsed, field) || Options.env(env) || Config.get(config, to_string(field))

      case decode(field, value) do
        {:ok, nil} -> {:cont, {:ok, limits}}
        {:ok, number} -> {:cont, {:ok, limits ++ [{field, number}]}}
        :error -> {:halt, {:error, "#{flag} / #{env} requires #{requirement(field)}"}}
      end
    end)
  end

  @spec restore(current :: keyword(), recorded :: map()) :: keyword()
  def restore(current, recorded) do
    recorded = get_in(recorded, ["harness_assembly", "limits"]) || %{}

    defaults =
      for field <- @fields,
          value = recorded[to_string(field)],
          not is_nil(value),
          do: {field, value}

    Keyword.merge(defaults, current)
  end

  @spec remember(harness :: Lemieux.Harness.t()) :: Lemieux.Harness.t()
  def remember(harness) do
    Lemieux.Harness.update_harness_context(harness, fn context ->
      case context do
        %{"assembly" => recipe} ->
          limits = Map.new(@fields, &{to_string(&1), Map.fetch!(harness, &1)})
          Map.put(context, "assembly", Map.put(recipe, "limits", limits))

        _other ->
          context
      end
    end)
  end

  defp decode(_field, nil), do: {:ok, nil}

  defp decode(field, value) when is_binary(value) do
    parsed = if field == :max_cost_usd, do: Float.parse(value), else: Integer.parse(value)

    case parsed do
      {number, ""} -> decode(field, number)
      _other -> :error
    end
  end

  defp decode(:max_cost_usd, value) when is_number(value) and value >= 0, do: {:ok, value}

  defp decode(field, value)
       when field in [:max_turns, :max_requests] and is_integer(value) and value > 0,
       do: {:ok, value}

  defp decode(_field, _value), do: :error

  defp requirement(:max_cost_usd), do: "a non-negative dollar amount"
  defp requirement(_field), do: "a positive integer"
end

defmodule Lemieux.CLI.Limits do
  @moduledoc false

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Options

  @fields [:max_turns, :max_requests, :max_cost_usd]
  @job_fields [:max_total_requests, :max_total_cost_usd]

  # The flag, then `LMX_MAX_TURNS`/`LMX_MAX_REQUESTS`/`LMX_MAX_COST_USD`, then
  # the config file. A blank variable counts as unset and falls through to the
  # file (`Lemieux.CLI.Options.env/1`), as every other variable `lmx` reads
  # does: `export LMX_MAX_TURNS=` or a template's unfilled line used to be
  # refused as "requires a positive integer", so every command stopped
  # before it started over a limit nobody had set.
  @spec parse(parsed :: keyword(), config :: Config.t()) ::
          {:ok, keyword()} | {:error, String.t()}
  def parse(parsed, config) do
    with {:ok, limits} <- parse_fields(@fields, parsed, config),
         {:ok, job} <- parse_fields(@job_fields, parsed, config) do
      case job do
        [] ->
          {:ok, limits}

        _ ->
          {:ok,
           Keyword.put(
             limits,
             :job_limits,
             Enum.map(job, fn {field, value} -> {job_field(field), value} end)
           )}
      end
    end
  end

  defp job_field(:max_total_requests), do: :max_requests
  defp job_field(:max_total_cost_usd), do: :max_cost_usd

  defp parse_fields(fields, parsed, config) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, limits} ->
      env = "LMX_" <> String.upcase(Atom.to_string(field))
      flag = "--" <> String.replace(Atom.to_string(field), "_", "-")

      value =
        Keyword.get(parsed, field) || Options.env(env) || Config.get(config, to_string(field))

      decoded = if field in @job_fields, do: job_field(field), else: field

      case decode(decoded, value) do
        {:ok, nil} -> {:cont, {:ok, limits}}
        {:ok, number} -> {:cont, {:ok, limits ++ [{field, number}]}}
        :error -> {:halt, {:error, "#{flag} / #{env} requires #{requirement(decoded)}"}}
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

    job =
      for field <- [:max_requests, :max_cost_usd],
          value = get_in(recorded, ["job_limits", to_string(field)]),
          not is_nil(value),
          do: {field, value}

    defaults = if job == [], do: defaults, else: Keyword.put(defaults, :job_limits, job)
    Keyword.merge(defaults, current)
  end

  @spec remember(harness :: Lemieux.Harness.t()) :: Lemieux.Harness.t()
  def remember(harness) do
    Lemieux.Harness.update_harness_context(harness, fn context ->
      case context do
        %{"assembly" => recipe} ->
          limits = Map.new(@fields, &{to_string(&1), Map.fetch!(harness, &1)})

          limits =
            Map.put(limits, "job_limits", job_map(harness.job_limits))

          Map.put(context, "assembly", Map.put(recipe, "limits", limits))

        _other ->
          context
      end
    end)
  end

  defp job_map(limits),
    do: Map.new(limits || [], fn {key, value} -> {Atom.to_string(key), value} end)

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

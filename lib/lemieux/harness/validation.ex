defmodule Lemieux.Harness.Validation do
  @moduledoc false

  @spec strategy!(value :: term(), field :: atom(), behaviour :: module()) :: {module(), term()}
  def strategy!({module, state}, field, behaviour) when is_atom(module) and not is_nil(module),
    do: {callbacks!(module, field, behaviour), state}

  def strategy!(module, field, behaviour) when is_atom(module) and not is_nil(module),
    do: {callbacks!(module, field, behaviour), nil}

  def strategy!(_value, field, behaviour),
    do:
      raise(
        ArgumentError,
        ":#{field} must be a module implementing #{inspect(behaviour)}, or {module, state}"
      )

  defp callbacks!(module, field, behaviour) do
    Code.ensure_loaded!(behaviour)
    loaded? = Code.ensure_loaded?(module)

    required =
      behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks)

    missing =
      Enum.reject(required, fn {name, arity} ->
        loaded? and function_exported?(module, name, arity)
      end)

    if missing != [] do
      names = Enum.map_join(missing, ", ", fn {name, arity} -> "#{name}/#{arity}" end)
      raise ArgumentError, ":#{field} #{inspect(module)} is missing callbacks: #{names}"
    end

    module
  end

  @spec description!(description :: map(), module :: module()) :: map()
  def description!(description, module) do
    # Encoder exceptions can contain private values. Check the data shape
    # before encoding and report only the author and field.
    if json?(description) do
      description
    else
      raise ArgumentError, "#{inspect(module)}.describe/1 must return JSON-compatible provenance"
    end
  end

  defp json?(%_{}), do: false

  defp json?(value) when is_map(value),
    do:
      Enum.all?(value, fn {key, item} -> is_binary(key) and String.valid?(key) and json?(item) end)

  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value), do: is_number(value) or is_boolean(value) or is_nil(value)
end

defmodule Lemieux.CLI.Runtime.Evaluation.ProfileDelta do
  @moduledoc false
  alias Lemieux.Learning.Discovery.Surface

  @spec changes(parent :: map(), candidate :: map()) :: {:ok, map()} | {:error, term()}
  def changes(parent, candidate) when is_map(parent) and is_map(candidate) do
    paths = Surface.changed_paths(parent, candidate)

    if Enum.all?(paths, &supported?/1) do
      delta(parent["options"], candidate["options"], paths)
    else
      {:error, :unsupported_profile_delta}
    end
  end

  defp supported?(path),
    do:
      path in ~w(options.system options.max_tokens options.temperature options.reasoning_effort options.tool_descriptions) or
        String.starts_with?(path, "options.tool_descriptions.")

  defp delta(parent, candidate, paths) do
    with {:ok, suffix} <- suffix(parent["system"], candidate["system"]) do
      generation =
        ~w(max_tokens temperature reasoning_effort)
        |> Enum.filter(&(("options." <> &1) in paths))
        |> Map.new(&{&1, candidate[&1]})

      descriptions = Map.get(candidate, "tool_descriptions", %{})
      original = Map.get(parent, "tool_descriptions", %{})

      # Removing a portable description has no faithful meaning on top of a
      # personal overlay: refuse instead of silently exposing another text.
      if Map.keys(original) -- Map.keys(descriptions) == [] do
        changed = changed_descriptions(descriptions, original)
        {:ok, compact(suffix, changed, generation)}
      else
        {:error, :unsupported_profile_delta}
      end
    end
  end

  defp changed_descriptions(descriptions, original),
    do: Map.reject(descriptions, fn {name, text} -> original[name] == text end)

  defp compact(suffix, changed, generation) do
    %{"system_suffix" => suffix, "tool_descriptions" => changed, "generation" => generation}
    |> Map.reject(fn {_key, value} -> value in ["", %{}] end)
  end

  defp suffix(same, same), do: {:ok, ""}

  defp suffix(parent, candidate) when is_binary(parent) and is_binary(candidate) do
    if String.starts_with?(candidate, parent),
      do:
        {:ok, binary_part(candidate, byte_size(parent), byte_size(candidate) - byte_size(parent))},
      else: {:error, :profile_prompt_must_append}
  end

  defp suffix(_parent, _candidate), do: {:error, :profile_prompt_must_append}
end

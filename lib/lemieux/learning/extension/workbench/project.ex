defmodule Lemieux.Learning.Extension.Workbench.Project do
  @moduledoc false

  alias Lemieux.Benchmark.Manifest

  @spec new(manifest :: Manifest.t(), names :: [String.t()]) :: map()
  def new(manifest, names) do
    tasks = Enum.map(manifest.tasks, &task/1)

    %{
      "version" => 1,
      "suite" => %{"version" => 1, "tasks" => tasks, "metadata" => manifest.metadata},
      "variants" => Map.new(names, &{&1, %{"base" => &1, "overrides" => %{}}}),
      "selected_cases" => Enum.map(tasks, & &1["id"]),
      "selected_variants" => names
    }
  end

  @spec task(task :: Lemieux.Benchmark.Task.t()) :: map()
  def task(task) do
    %{
      "id" => task.id,
      "prompt" => task.prompt,
      "cwd" => task.cwd,
      "timeout_ms" => task.timeout_ms,
      "metadata" => task.metadata,
      "grader" => %{
        "command" => task.grader.command,
        "env" => task.grader.env,
        "timeout_ms" => task.grader.timeout_ms,
        "max_output_bytes" => task.grader.max_output_bytes
      }
    }
  end

  @spec validate(project :: map(), registry :: map(), base_dir :: Path.t()) ::
          :ok | {:error, term()}
  def validate(
        %{"version" => 1, "suite" => suite, "variants" => variants} = project,
        registry,
        base_dir
      )
      when is_map(variants) and map_size(variants) > 0 do
    with {:ok, manifest} <- Manifest.from_map(suite, base_dir),
         :ok <- validate_variants(variants, registry),
         :ok <- selection(project["selected_cases"], Enum.map(manifest.tasks, & &1.id)) do
      selection(project["selected_variants"], Map.keys(variants))
    end
  end

  def validate(_project, _registry, _base_dir), do: {:error, :invalid_workbench_project}

  @spec selection(selected :: term(), available :: [String.t()]) :: :ok | {:error, term()}
  def selection(selected, available) when is_list(selected) and selected != [] do
    if Enum.uniq(selected) == selected and Enum.all?(selected, &(&1 in available)),
      do: :ok,
      else: {:error, :invalid_selection}
  end

  def selection(_selected, _available), do: {:error, :invalid_selection}

  @spec variant(name :: term(), variant :: term(), registry :: map()) :: :ok | {:error, term()}
  def variant(name, %{"base" => base, "overrides" => overrides}, registry)
      when is_map(overrides) do
    if name?(name) and Map.has_key?(registry, base) and Enum.all?(overrides, &override?/1),
      do: :ok,
      else: {:error, :invalid_variant}
  end

  def variant(_name, _variant, _registry), do: {:error, :invalid_variant}

  @spec name?(name :: term()) :: boolean()
  def name?(name) when is_binary(name),
    do: Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}\z/, name)

  def name?(_name), do: false

  defp validate_variants(variants, registry) do
    Enum.reduce_while(variants, :ok, fn {name, value}, :ok ->
      case variant(name, value, registry) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp override?({"system", value}), do: is_binary(value)
  defp override?({"model", value}), do: is_binary(value) and value != ""
  defp override?({"max_turns", value}), do: is_integer(value) and value > 0
  defp override?({"reasoning_effort", value}), do: is_binary(value) and value != ""
  defp override?({"temperature", value}), do: is_number(value) and value >= 0 and value <= 2
  defp override?(_entry), do: false
end

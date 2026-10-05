defmodule Lemieux.Benchmark.FixtureSet do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Versioned configuration for one or more recorded benchmark variants.
  """

  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Benchmark.Runtime.Fixture

  @doc "Reads fixture variants and resolves observation paths relative to the set file."
  @spec read(path :: Path.t()) ::
          {:ok, %{runtimes: [Runtime.t()], baseline: String.t()}}
          | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- decode(body),
         {:ok, variants, baseline} <- validate(decoded) do
      base_dir = path |> Path.expand() |> Path.dirname()

      runtimes =
        Enum.map(variants, fn %{"name" => name, "observations" => observations} ->
          Runtime.new(name, Fixture, path: Path.expand(observations, base_dir))
        end)

      {:ok, %{runtimes: runtimes, baseline: baseline || hd(runtimes).name}}
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error, {:invalid_fixture_set_json, Lemieux.JSON.describe_error(reason)}}
    end
  end

  defp validate(%{"version" => 1, "variants" => variants} = fixture_set)
       when is_list(variants) and variants != [] do
    if Enum.all?(variants, &variant?/1) and unique_names?(variants) do
      {:ok, variants, Map.get(fixture_set, "baseline")}
    else
      {:error, :invalid_fixture_variants}
    end
  end

  defp validate(%{"version" => version}),
    do: {:error, {:unsupported_fixture_set_version, version}}

  defp validate(_fixture_set), do: {:error, :invalid_fixture_set}

  defp variant?(%{"name" => name, "observations" => path}),
    do: is_binary(name) and name != "" and is_binary(path) and path != ""

  defp variant?(_variant), do: false

  defp unique_names?(variants) do
    names = Enum.map(variants, & &1["name"])
    length(names) == MapSet.size(MapSet.new(names))
  end
end

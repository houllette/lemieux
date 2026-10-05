defmodule Lemieux.Learning.Discovery.Surface do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  The bounded edit surface for profile-shaped candidates, checked mechanically.

  Every 2026 self-improving harness that reports stable gains restricts what
  the proposer may touch — AlphaEvolve's evolve-block markers, Self-Harness's
  declared configuration points, HarnessX's typed substitutions. The reason
  is not tidiness: a proposer that can edit anything will eventually edit the
  thing that measures it. The Darwin Gödel Machine's evolved agent removed
  the logging markers its evaluator relied on; STOP's self-improver tried to
  delete sandbox markers. A prompt telling the model not to is not a boundary.

  Here the boundary is data the plan freezes: `plan.mutation_surface` lists
  dotted paths inside a `Lemieux.Extension.Profile` document, and a candidate
  is accepted only if it differs from its parent at those paths alone. Two
  hard constraints are checked at the same time because they are about the
  bytes rather than the scores: `forbidden_references` (grader paths and
  markers the candidate must not mention) and `max_content_bytes`.

  The validator has an identity. `validator/0` is what a plan pins as its
  `interface_validator`, so a candidate records which rules admitted it and a
  later reader can tell whether those rules have changed since.
  """

  alias Lemieux.Contract
  alias Lemieux.Learning.Discovery.Plan

  @validator_id "lemieux.profile-surface/v1"

  @doc "The immutable identity a plan pins as its interface validator."
  @spec validator() :: %{String.t() => String.t()}
  def validator, do: %{"id" => @validator_id, "sha256" => Contract.sha256(@validator_id)}

  @doc "Dotted paths at which two JSON documents differ; lists compare as leaves."
  @spec changed_paths(parent :: map(), candidate :: map()) :: [String.t()]
  def changed_paths(parent, candidate) when is_map(parent) and is_map(candidate) do
    parent
    |> diff(candidate, [])
    |> Enum.map(&Enum.join(&1, "."))
    |> Enum.sort()
  end

  @doc """
  Validates candidate bytes against the plan's surface and byte-level hard
  constraints. Returns the changed paths on success. `operator` `"seed"`
  permits an unchanged document; every other operator must change something.
  """
  @spec validate(
          plan :: Plan.t(),
          parent :: map(),
          candidate :: map(),
          bytes :: binary(),
          operator :: String.t()
        ) :: {:ok, %{String.t() => term()}} | {:error, term()}
  def validate(%Plan{} = plan, parent, candidate, bytes, operator)
      when is_map(parent) and is_map(candidate) and is_binary(bytes) and is_binary(operator) do
    changed = changed_paths(parent, candidate)
    allowed = allowed_paths(plan)

    with :ok <- within_surface(changed, allowed),
         :ok <- changed_or_seed(changed, operator),
         :ok <- forbidden_references(plan, bytes),
         :ok <- size(plan, bytes) do
      {:ok, %{"changed_paths" => changed, "size_bytes" => byte_size(bytes)}}
    end
  end

  @doc "Builds the candidate's `interface_validation` record from a validate/5 result."
  @spec interface_validation(result :: {:ok, map()} | {:error, term()}) :: map()
  def interface_validation({:ok, detail}) do
    %{
      "status" => "passed",
      "validator_sha256" => validator()["sha256"],
      "validator_id" => @validator_id,
      "detail" => detail
    }
  end

  def interface_validation({:error, reason}) do
    %{
      "status" => "failed",
      "validator_sha256" => validator()["sha256"],
      "validator_id" => @validator_id,
      "detail" => %{"error" => Contract.json(reason)}
    }
  end

  @doc "The dotted paths a plan permits, from its mutation surface."
  @spec allowed_paths(plan :: Plan.t()) :: [String.t()]
  def allowed_paths(%Plan{mutation_surface: surface}) do
    surface
    |> Enum.map(&Map.get(&1, "path"))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp within_surface(changed, allowed) do
    outside =
      Enum.reject(changed, fn path ->
        Enum.any?(allowed, &(path == &1 or String.starts_with?(path, &1 <> ".")))
      end)

    if outside == [], do: :ok, else: {:error, {:outside_surface, outside}}
  end

  defp changed_or_seed([], "seed"), do: :ok
  defp changed_or_seed([], _operator), do: {:error, :no_change}
  defp changed_or_seed(_changed, _operator), do: :ok

  defp forbidden_references(plan, bytes) do
    patterns =
      plan.hard_constraints
      |> Enum.filter(&(&1["kind"] == "forbidden_references"))
      |> Enum.flat_map(&List.wrap(&1["patterns"]))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    haystack = String.downcase(bytes)

    case Enum.find(patterns, &String.contains?(haystack, String.downcase(&1))) do
      nil -> :ok
      pattern -> {:error, {:forbidden_reference, pattern}}
    end
  end

  defp size(plan, bytes) do
    plan.hard_constraints
    |> Enum.find(&(&1["kind"] == "max_content_bytes"))
    |> case do
      %{"value" => max} when is_integer(max) and byte_size(bytes) > max ->
        {:error, {:content_too_large, byte_size(bytes), max}}

      _none ->
        :ok
    end
  end

  defp diff(parent, candidate, prefix) when is_map(parent) and is_map(candidate) do
    keys = Enum.uniq(Map.keys(parent) ++ Map.keys(candidate))

    Enum.flat_map(keys, fn key ->
      case {Map.fetch(parent, key), Map.fetch(candidate, key)} do
        {{:ok, left}, {:ok, right}} when is_map(left) and is_map(right) ->
          diff(left, right, prefix ++ [key])

        {{:ok, same}, {:ok, same}} ->
          []

        _changed ->
          [prefix ++ [key]]
      end
    end)
  end
end

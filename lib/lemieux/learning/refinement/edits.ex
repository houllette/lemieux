defmodule Lemieux.Learning.Refinement.Edits do
  @moduledoc false
  alias Lemieux.Contract
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Surface

  @spec admit(plan :: struct(), baseline :: map(), candidates :: list(), artifacts :: map()) ::
          {list(), list()}
  def admit(plan, baseline, candidates, artifacts) do
    Enum.reduce(candidates, {[], []}, fn candidate, {accepted, rejected} ->
      case validate(plan, baseline, candidate, artifacts) do
        {:ok, item} ->
          {accepted ++ [item], rejected}

        {:error, _reason} ->
          {accepted,
           rejected ++ [%{"candidate" => id(candidate), "reason" => "unsupported_candidate"}]}
      end
    end)
  end

  defp validate(plan, baseline, %Candidate{} = candidate, artifacts) do
    bytes = artifacts[candidate.content.sha256]

    with :ok <- Candidate.verify(candidate),
         true <- candidate.plan_sha256 == plan.sha256 and candidate.scope == plan.scope,
         :ok <- Candidate.verify_lineage([candidate], plan.seeds),
         true <- artifact?(candidate.rationale, artifacts),
         true <- artifact?(candidate.content, artifacts),
         {:ok, profile} <- JSON.decode(bytes),
         :ok <- Profile.validate(profile),
         true <-
           Enum.any?(candidate.parents, &(&1["content_sha256"] == Contract.digest(baseline))),
         mechanism when is_binary(mechanism) and byte_size(mechanism) in 1..256 <-
           candidate.extensions["mechanism"],
         {:ok, detail} <- Surface.validate(plan, baseline, profile, bytes, "task_local") do
      {:ok,
       %{
         candidate: candidate,
         profile: profile,
         paths: detail["changed_paths"],
         digest: candidate.content.sha256
       }}
    else
      _invalid -> {:error, :unsupported_candidate}
    end
  end

  defp validate(_plan, _baseline, _candidate, _artifacts), do: {:error, :unsupported_candidate}

  defp artifact?(reference, artifacts) do
    bytes = artifacts[reference.sha256]

    is_binary(bytes) and byte_size(bytes) <= 16_384 and byte_size(bytes) == reference.size_bytes and
      Contract.sha256(bytes) == reference.sha256
  end

  defp id(%Candidate{id: id}), do: id
  defp id(_invalid), do: "invalid"

  @doc "Excludes both sides of conflicting edits rather than resolving by order."
  @spec compose(baseline :: map(), supported :: list()) :: {map(), list(), list()}
  def compose(baseline, supported) do
    conflicting =
      Enum.filter(supported, fn item -> Enum.any?(supported, &conflict?(item, &1)) end)

    kept = supported -- conflicting

    profile =
      Enum.reduce(kept, baseline, fn item, profile ->
        Enum.reduce(item.paths, profile, fn path, acc ->
          keys = String.split(path, ".")
          put(acc, keys, fetch(item.profile, keys))
        end)
      end)

    {profile, kept,
     Enum.map(conflicting, &%{"candidate" => &1.candidate.id, "reason" => "conflicting_edit"})}
  end

  defp conflict?(a, b) do
    a.digest != b.digest and
      Enum.any?(a.paths, fn left ->
        Enum.any?(b.paths, fn right ->
          overlap =
            left == right or String.starts_with?(left, right <> ".") or
              String.starts_with?(right, left <> ".")

          overlap and
            get_in(a.profile, String.split(left, ".")) !=
              get_in(b.profile, String.split(left, "."))
        end)
      end)
  end

  defp fetch(map, [key]), do: Map.fetch(map, key)
  defp fetch(map, [key | rest]), do: fetch(Map.get(map, key, %{}), rest)
  defp put(map, [key], {:ok, value}), do: Map.put(map, key, value)
  defp put(map, [key], :error), do: Map.delete(map, key)

  defp put(map, [key | rest], value),
    do: Map.put(map, key, put(Map.get(map, key, %{}), rest, value))
end

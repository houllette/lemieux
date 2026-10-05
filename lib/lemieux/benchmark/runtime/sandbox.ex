defmodule Lemieux.Benchmark.Runtime.Sandbox do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Fail-closed evidence contract for host-provided isolated benchmark runtimes.

  Lemieux intentionally does not provision a microVM. A host runtime already
  plugs into `Lemieux.Benchmark.Runtime`; this module validates the additional
  evidence that runtime must return before a safety-scoped result is usable.
  Process separation, local copies and Git worktrees are not attestations.

  The verifier is host code and should validate a signature from the sandbox
  service over the complete evidence record. An optimizer receives neither
  that identity nor the verifier authority.
  """

  defmodule Result do
    @moduledoc """
    **Experimental.** May change in any 0.x release.
    Normalized, host-verified sandbox evidence.
    """

    @type t :: %__MODULE__{
            workspace_image_digest: String.t(),
            repository_digest: String.t(),
            changed_paths: [Path.t()],
            violations: [map() | String.t()],
            attestation: map() | nil
          }

    @enforce_keys [:workspace_image_digest, :repository_digest, :changed_paths, :violations]
    defstruct [
      :workspace_image_digest,
      :repository_digest,
      :attestation,
      changed_paths: [],
      violations: []
    ]
  end

  @doc "Validates and normalizes one runtime observation."
  @spec validate(observation :: map(), opts :: keyword()) :: {:ok, Result.t()} | {:error, term()}
  def validate(observation, opts \\ []) when is_map(observation) and is_list(opts) do
    safety_scoped? = Keyword.get(opts, :safety_scoped, false)

    with {:ok, image} <- nonempty(observation, "workspace_image_digest"),
         {:ok, repository} <- nonempty(observation, "repository_digest"),
         {:ok, paths} <- list(observation, "changed_paths"),
         {:ok, violations} <- list(observation, "sandbox_violations"),
         {:ok, attestation} <- attestation(observation, safety_scoped?, opts) do
      {:ok,
       %Result{
         workspace_image_digest: image,
         repository_digest: repository,
         changed_paths: paths,
         violations: violations,
         attestation: attestation
       }}
    end
  end

  defp attestation(observation, false, _opts), do: {:ok, Map.get(observation, "attestation")}

  defp attestation(observation, true, opts) do
    case {Map.get(observation, "attestation"), Keyword.get(opts, :attestation_verifier)} do
      {nil, _verifier} ->
        {:error, :attestation_missing}

      {_attestation, nil} ->
        {:error, :attestation_verifier_missing}

      {attestation, verifier} when is_function(verifier, 1) ->
        case verifier.(attestation) do
          :ok -> {:ok, attestation}
          {:error, reason} -> {:error, {:attestation_invalid, reason}}
          other -> {:error, {:invalid_attestation_verifier_result, other}}
        end
    end
  end

  defp nonempty(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _invalid -> {:error, {:invalid_sandbox_field, key}}
    end
  end

  defp list(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> {:ok, value}
      _invalid -> {:error, {:invalid_sandbox_field, key}}
    end
  end
end

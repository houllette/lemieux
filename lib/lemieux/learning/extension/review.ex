defmodule Lemieux.Learning.Extension.Review do
  @moduledoc """
  **Experimental.** Not part of the stable public API.

  Explicit host review of executable export bytes.

  A complete CodeGate is bound to the source export's entire file inventory.
  A reviewer names the same digest and approves export, never deployment.
  These host-provided attestations remain evidence references rather than a
  signature or a sandbox. Candidates cannot authorize their own export by
  changing a manifest flag. Independent behavioral confirmation is separate.
  """
  alias Lemieux.Contract
  alias Lemieux.Experiment.CodeGate

  @spec verify(files :: map(), gate :: map(), review :: map()) :: :ok | {:error, term()}
  def verify(files, gate, review) when is_map(files) and is_map(gate) and is_map(review) do
    digest = Contract.digest(files)

    with true <- Enum.sort(Map.keys(gate)) == ~w(content_sha256 evidence),
         true <- gate["content_sha256"] == digest and is_map(gate["evidence"]),
         true <- evidence?(gate["evidence"]),
         {:ok, _reviewable} <- CodeGate.evaluate(gate["evidence"]),
         true <- Enum.sort(Map.keys(review)) == ~w(actor content_sha256 decision),
         true <-
           review["content_sha256"] == digest and review["decision"] == "approved_for_export",
         actor when is_binary(actor) and byte_size(actor) in 1..256 <- review["actor"] do
      :ok
    else
      _missing -> {:error, :executable_export_requires_bound_gate_and_human_review}
    end
  end

  def verify(_files, _gate, _review),
    do: {:error, :executable_export_requires_bound_gate_and_human_review}

  defp evidence?(evidence) do
    Enum.sort(Map.keys(evidence)) == Enum.sort(CodeGate.required_evidence()) and
      Enum.all?(evidence, fn {_kind, row} ->
        is_map(row) and Enum.sort(Map.keys(row)) == ~w(digest passed) and
          is_binary(row["digest"]) and Regex.match?(~r/\A[a-f0-9]{64}\z/, row["digest"])
      end)
  end
end

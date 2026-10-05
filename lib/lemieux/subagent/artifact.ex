defmodule Lemieux.Subagent.Artifact do
  @moduledoc "Version checks for by-reference child artifacts."

  @doc "Verifies a file artifact against its recorded SHA-256 digest."
  @spec verify(artifact :: map()) :: :ok | {:error, term()}
  def verify(%{"kind" => "file", "ref" => path, "digest" => expected})
      when is_binary(path) and is_binary(expected) do
    with {:ok, contents} <- File.read(path) do
      actual = contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      if secure_compare(actual, String.downcase(expected)),
        do: :ok,
        else: {:error, {:stale, %{ref: path, expected: expected, actual: actual}}}
    end
  end

  def verify(%{"kind" => kind}), do: {:error, {:unsupported_artifact_kind, kind}}
  def verify(_artifact), do: {:error, :invalid_artifact}

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_compare(_left, _right), do: false
end

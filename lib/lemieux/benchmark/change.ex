defmodule Lemieux.Benchmark.Change do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Validates the change identity attached to an evaluation gate.

  Lemieux releases and dependency versions use SemVer. This task is narrowly a
  minor-bump gate, so patch and major transitions are rejected rather than
  silently evaluated under the wrong policy. Models, prompts and tool schemas
  use host-owned stable identifiers because their version vocabularies are not
  SemVer.
  """

  @semver_kinds ~w(release dependency)
  @identifier_kinds ~w(model prompt tool_schema)

  @doc "Validates a from/to pair for the selected change kind."
  @spec validate(kind :: String.t(), from :: String.t(), to :: String.t()) ::
          :ok | {:error, term()}
  def validate(kind, from, to) when kind in @semver_kinds do
    with {:ok, from_version} <- version(from),
         {:ok, to_version} <- version(to) do
      if minor_bump?(from_version, to_version), do: :ok, else: {:error, :not_a_minor_bump}
    end
  end

  def validate(kind, from, to)
      when kind in @identifier_kinds and is_binary(from) and from != "" and is_binary(to) and
             to != "" and from != to,
      do: :ok

  def validate(kind, _from, _to) when kind in @identifier_kinds,
    do: {:error, :invalid_change_identifiers}

  def validate(kind, _from, _to), do: {:error, {:unsupported_change_kind, kind}}

  defp version(value) when is_binary(value) do
    case Version.parse(value) do
      {:ok, version} -> {:ok, version}
      :error -> {:error, {:invalid_version, value}}
    end
  end

  defp minor_bump?(from, to) do
    to.major == from.major and to.minor == from.minor + 1 and to.patch == 0 and
      Version.compare(to, from) == :gt
  end
end

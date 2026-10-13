defmodule Lemieux.Writers.Artifact do
  @moduledoc "A content-addressed patch and complete report tied to an immutable base."
  @enforce_keys [
    :writer_id,
    :base_revision,
    :base_tree,
    :tree,
    :paths,
    :transcript_id,
    :patch_path,
    :patch_sha256,
    :report_path,
    :report_sha256,
    :verification
  ]
  defstruct @enforce_keys ++ [:digest]

  @type t :: %__MODULE__{
          writer_id: String.t(),
          base_revision: String.t(),
          base_tree: String.t(),
          tree: String.t(),
          paths: [String.t()],
          transcript_id: String.t(),
          patch_path: Path.t(),
          patch_sha256: String.t(),
          report_path: Path.t(),
          report_sha256: String.t(),
          verification: map(),
          digest: String.t() | nil
        }

  @doc "Seals the entire manifest; review accepts this digest, not a mutable writer name."
  @spec seal(artifact :: t()) :: t()
  def seal(artifact), do: %{artifact | digest: digest(artifact)}

  @doc "Checks manifest identity and both complete files before integration."
  @spec verify(artifact :: t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = artifact) do
    with true <- valid_shape?(artifact),
         true <- artifact.digest == digest(artifact),
         {:ok, patch} <- File.read(artifact.patch_path),
         true <- hash(patch) == artifact.patch_sha256,
         {:ok, report} <- File.read(artifact.report_path),
         true <- hash(report) == artifact.report_sha256,
         {:ok, stored} <- File.read(manifest_path(artifact)),
         {:ok, decoded} <- JSON.decode(stored),
         true <- decoded == manifest(artifact) do
      :ok
    else
      _invalid -> {:error, :artifact_changed}
    end
  end

  @doc "The complete manifest, retained beside the patch and report."
  @spec manifest(artifact :: t()) :: map()
  def manifest(artifact) do
    artifact |> Map.from_struct() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc "A bounded parent-transcript reference to the complete manifest."
  @spec reference(artifact :: t()) :: map()
  def reference(artifact) do
    %{
      "digest" => artifact.digest,
      "manifest_path" => manifest_path(artifact),
      "transcript_id" => artifact.transcript_id,
      "base_revision" => artifact.base_revision
    }
  end

  @doc "The content-addressed manifest's location."
  @spec manifest_path(artifact :: t()) :: Path.t()
  def manifest_path(artifact),
    do: Path.join(Path.dirname(artifact.patch_path), artifact.digest <> ".manifest.json")

  @doc false
  @spec hash(bytes :: binary()) :: String.t()
  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp valid_shape?(artifact) do
    binaries = [
      :writer_id,
      :base_revision,
      :base_tree,
      :tree,
      :transcript_id,
      :patch_path,
      :patch_sha256,
      :report_path,
      :report_sha256,
      :digest
    ]

    Enum.all?(binaries, &(is_binary(Map.get(artifact, &1)) and Map.get(artifact, &1) != "")) and
      is_list(artifact.paths) and is_map(artifact.verification)
  end

  defp digest(artifact) do
    artifact
    |> Map.from_struct()
    |> Map.delete(:digest)
    |> :erlang.term_to_binary([:deterministic])
    |> hash()
  end
end

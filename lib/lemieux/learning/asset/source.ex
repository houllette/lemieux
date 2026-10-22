defmodule Lemieux.Learning.Asset.Source do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Source files for a typed asset inside an ordinary native Mix extension.

  `write/3` preserves the asset's identity and complete file tree. Declare
  `asset.json` and every file under `files/` in the owning project's existing
  `lemieux-extension.json`, including its dependency graph. The existing
  extension export, frozen build, independent confirmation and CodeGate lane
  then bind these bytes with the owner's source; no code is generated here.

  `read/2` revalidates the receiving host's current scope, runtime binding,
  tools and trust through the normal typed-asset validator and actual skill
  loader. The source carries no approvals, active pointers or qualification.
  Self-consistent checksums are integrity metadata, never host authority.
  Keep the expected package/build digest separately and verify it through
  `Lemieux.Learning.Extension.Export` before use. A native package's scoped
  confirmation does not independently qualify every asset it contains.

  Load with `{Lemieux.Learning.Asset.Extension, source: root, context: context}`.
  The host must supply fresh exact-digest approval. Retain the original harness
  and reassemble without the extension to restore it exactly.
  """

  alias Lemieux.Asset.Version
  alias Lemieux.Contract
  alias Lemieux.Learning.Asset
  alias Lemieux.Learning.Extension.Tree

  @fields ~w(schema_version asset_id asset_sha256 created_at content runtime sha256)
  @asset_fields ~w(kind payload files requires_tools triggers)
  @maximum_bytes 131_072

  @doc "Writes a new source tree without overwriting files or exporting host authority."
  @spec write(version :: Version.t(), root :: Path.t(), context :: map()) ::
          :ok | {:error, term()}
  def write(%Version{} = version, root, context) do
    with :ok <- Asset.verify(version, context),
         document = document(version),
         {:ok, ^version} <- version(document, context),
         true <- byte_size(Contract.encode!(document)) <= @maximum_bytes,
         :ok <- File.mkdir(root) do
      result = write_into(version, root, context, document)
      if match?({:error, _}, result), do: File.rm_rf(root)
      result
    else
      false -> {:error, :asset_source_too_large}
      {:ok, _changed} -> {:error, :unsupported_asset_source_metadata}
      error -> error
    end
  end

  @doc "Reconstructs the exact version and validates every installed file without granting approval."
  @spec read(root :: Path.t(), context :: map()) ::
          {:ok, Version.t(), Path.t()} | {:error, term()}
  def read(root, context) do
    root = Path.expand(root)
    files = Path.join(root, "files")

    with :ok <- layout(root),
         {:ok, document} <- Tree.read(Path.join(root, "asset.json")),
         {:ok, version} <- version(document, context),
         {:ok, _skill} <- Asset.installed(version, files, context) do
      {:ok, version, files}
    end
  end

  defp write_into(version, root, context, document) do
    with :ok <- File.chmod(root, 0o700),
         {:ok, _skill} <- Asset.materialize(version, Path.join(root, "files"), context),
         :ok <- Tree.write(Path.join(root, "asset.json"), document) do
      File.chmod(Path.join(root, "asset.json"), 0o600)
    end
  end

  defp document(version) do
    document = %{
      "schema_version" => 1,
      "asset_id" => version.id,
      "asset_sha256" => version.digest,
      "created_at" => DateTime.to_iso8601(version.created_at),
      "content" => version.content,
      "runtime" => runtime()
    }

    Map.put(document, "sha256", Contract.digest(document))
  end

  defp version(document, context) do
    with true <- Enum.sort(Map.keys(document)) == Enum.sort(@fields),
         true <- document["schema_version"] == 1 and document["runtime"] == runtime(),
         :ok <- Contract.verify_digest(document, "sha256"),
         id when is_binary(id) and byte_size(id) in 1..256 <- document["asset_id"],
         timestamp when is_binary(timestamp) <- document["created_at"],
         {:ok, created_at, 0} <- DateTime.from_iso8601(timestamp),
         content when is_map(content) <- document["content"],
         {:ok, version} <- Asset.new(Map.take(content, @asset_fields), context),
         true <- version.content == content and version.digest == document["asset_sha256"] do
      {:ok, %{version | id: id, created_at: created_at}}
    else
      _invalid -> {:error, :invalid_asset_source}
    end
  end

  defp layout(root) do
    with {:ok, %{type: :directory}} <- File.lstat(root),
         {:ok, names} <- File.ls(root),
         true <- Enum.sort(names) == ~w(asset.json files),
         {:ok, %{type: :regular, size: size}} <- File.lstat(Path.join(root, "asset.json")),
         true <- size <= @maximum_bytes do
      :ok
    else
      _unsafe -> {:error, :invalid_asset_source_layout}
    end
  end

  defp runtime,
    do: %{
      "lemieux" => Lemieux.version(),
      "elixir" => System.version(),
      "otp" => System.otp_release()
    }
end

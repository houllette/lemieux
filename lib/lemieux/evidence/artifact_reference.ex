defmodule Lemieux.Evidence.ArtifactReference do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A content-addressed reference used by evidence and discovery contracts.

  A locator is deliberately optional and never grants access. Hosts resolve a
  locator only after their own scope and retention checks; Lemieux verifies
  bytes and records media/schema identity without acquiring a database or
  artifact-store dependency.
  """

  alias Lemieux.Contract

  @version 1

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          kind: String.t(),
          sha256: String.t(),
          size_bytes: non_neg_integer(),
          media_type: String.t(),
          content_schema: String.t(),
          locator: String.t() | nil,
          scope: map()
        }

  @enforce_keys [:id, :kind, :sha256, :size_bytes, :media_type, :content_schema, :scope]
  defstruct schema_version: @version,
            id: nil,
            kind: nil,
            sha256: nil,
            size_bytes: nil,
            media_type: nil,
            content_schema: nil,
            locator: nil,
            scope: %{}

  @doc "Builds and validates a content reference."
  @spec new(attrs :: map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    attrs = Contract.json(attrs)

    with :ok <- required_string(attrs, "id"),
         :ok <- required_string(attrs, "kind"),
         :ok <- digest(attrs["sha256"]),
         :ok <- size(attrs["size_bytes"]),
         :ok <- required_string(attrs, "media_type"),
         :ok <- required_string(attrs, "content_schema"),
         :ok <- scope(attrs["scope"]) do
      {:ok,
       %__MODULE__{
         id: attrs["id"],
         kind: attrs["kind"],
         sha256: attrs["sha256"],
         size_bytes: attrs["size_bytes"],
         media_type: attrs["media_type"],
         content_schema: attrs["content_schema"],
         locator: attrs["locator"],
         scope: attrs["scope"]
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_artifact_reference}

  @doc "Creates a reference from caller-supplied bytes."
  @spec from_bytes(kind :: String.t(), bytes :: iodata(), keyword()) :: t()
  def from_bytes(kind, bytes, opts \\ []) when is_binary(kind) do
    bytes = IO.iodata_to_binary(bytes)
    digest = Contract.sha256(bytes)

    %__MODULE__{
      id: Keyword.get(opts, :id, "artifact_" <> digest),
      kind: kind,
      sha256: digest,
      size_bytes: byte_size(bytes),
      media_type: Keyword.get(opts, :media_type, "application/octet-stream"),
      content_schema: Keyword.get(opts, :content_schema, "opaque/v1"),
      locator: Keyword.get(opts, :locator),
      scope: opts |> Keyword.get(:scope, %{}) |> Contract.json()
    }
  end

  @doc "Verifies bytes against both the recorded length and SHA-256."
  @spec verify_bytes(reference :: t(), bytes :: iodata()) ::
          :ok | {:error, :size_mismatch | :digest_mismatch}
  def verify_bytes(%__MODULE__{} = reference, bytes) do
    bytes = IO.iodata_to_binary(bytes)

    cond do
      byte_size(bytes) != reference.size_bytes -> {:error, :size_mismatch}
      Contract.sha256(bytes) != reference.sha256 -> {:error, :digest_mismatch}
      true -> :ok
    end
  end

  @doc "Returns the JSON-shaped reference."
  @spec to_map(reference :: t()) :: map()
  def to_map(%__MODULE__{} = reference) do
    %{
      "schema_version" => reference.schema_version,
      "id" => reference.id,
      "kind" => reference.kind,
      "sha256" => reference.sha256,
      "size_bytes" => reference.size_bytes,
      "media_type" => reference.media_type,
      "content_schema" => reference.content_schema,
      "locator" => reference.locator,
      "scope" => reference.scope
    }
  end

  @doc "Rebuilds a reference from its wire representation."
  @spec from_map(map :: map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{"schema_version" => @version} = map), do: new(map)

  def from_map(%{"schema_version" => version}),
    do: {:error, {:unsupported_version, version}}

  def from_map(_map), do: {:error, :missing_schema_version}

  defp required_string(attrs, key) do
    case attrs[key] do
      value when is_binary(value) and value != "" -> :ok
      _invalid -> {:error, {:invalid_artifact_field, key}}
    end
  end

  defp digest(value) when is_binary(value) and byte_size(value) == 64, do: :ok
  defp digest(_value), do: {:error, {:invalid_artifact_field, "sha256"}}

  defp size(value) when is_integer(value) and value >= 0, do: :ok
  defp size(_value), do: {:error, {:invalid_artifact_field, "size_bytes"}}

  defp scope(value) when is_map(value), do: :ok
  defp scope(_value), do: {:error, {:invalid_artifact_field, "scope"}}
end

defmodule Lemieux.Asset.Version do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  One immutable version of a durable harness asset.

  Content is addressed by a SHA-256 digest and linked to its parent and
  rollback target. Activation is a separate operation, so approving or rolling
  back an asset changes a pointer rather than rewriting historical evidence.
  A version describes policy content; it never loads code into the current VM.
  """

  alias Lemieux.ID

  @types ~w(prompt tool_description workflow configuration project_instruction harness_code)a
  @layers ~w(release host tenant project session)a
  @scopes ~w(release global tenant project task session)a

  @type asset_type ::
          :prompt
          | :tool_description
          | :workflow
          | :configuration
          | :project_instruction
          | :harness_code
  @type layer :: :release | :host | :tenant | :project | :session
  @type scope :: :release | :global | :tenant | :project | :task | :session

  @type t :: %__MODULE__{
          id: String.t(),
          type: asset_type(),
          layer: layer(),
          scope: scope(),
          tenant_id: String.t() | nil,
          project_id: String.t() | nil,
          parent_id: String.t() | nil,
          rollback_target_id: String.t() | nil,
          digest: String.t(),
          content: term(),
          semantic_diff: String.t() | nil,
          size_bytes: non_neg_integer(),
          token_count: non_neg_integer(),
          safety: map(),
          authored_by: map(),
          motivating_feedback_ids: [String.t()],
          experiment_id: String.t() | nil,
          created_at: DateTime.t()
        }

  @enforce_keys [:id, :type, :layer, :scope, :digest, :content, :created_at]
  defstruct [
    :id,
    :type,
    :layer,
    :scope,
    :tenant_id,
    :project_id,
    :parent_id,
    :rollback_target_id,
    :digest,
    :content,
    :semantic_diff,
    :created_at,
    size_bytes: 0,
    token_count: 0,
    safety: %{},
    authored_by: %{"type" => "human", "id" => "local"},
    motivating_feedback_ids: [],
    experiment_id: nil
  ]

  @doc "Builds and digests an immutable asset version."
  @spec new(attrs :: map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    type = Map.get(attrs, :type)
    layer = Map.get(attrs, :layer)
    scope = Map.get(attrs, :scope)
    content = Map.get(attrs, :content)
    safety = Map.get(attrs, :safety, %{})

    with :ok <- known(type, @types, :type),
         :ok <- known(layer, @layers, :layer),
         :ok <- known(scope, @scopes, :scope),
         :ok <- validate_identity(scope, attrs),
         :ok <- validate_content(content),
         :ok <- validate_safety(safety) do
      encoded = encode_content(content)
      digest = digest(type, layer, scope, content, safety)

      {:ok,
       %__MODULE__{
         id: Map.get(attrs, :id, "asset_" <> ID.generate()),
         type: type,
         layer: layer,
         scope: scope,
         tenant_id: Map.get(attrs, :tenant_id),
         project_id: Map.get(attrs, :project_id),
         parent_id: Map.get(attrs, :parent_id),
         rollback_target_id: Map.get(attrs, :rollback_target_id) || Map.get(attrs, :parent_id),
         digest: digest,
         content: content,
         semantic_diff: Map.get(attrs, :semantic_diff),
         size_bytes: byte_size(encoded),
         token_count: Map.get(attrs, :token_count, approximate_tokens(encoded)),
         safety: safety,
         authored_by: Map.get(attrs, :authored_by, %{"type" => "human", "id" => "local"}),
         motivating_feedback_ids: Map.get(attrs, :motivating_feedback_ids, []),
         experiment_id: Map.get(attrs, :experiment_id),
         created_at: Map.get_lazy(attrs, :created_at, &DateTime.utc_now/0)
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_asset_version}

  @doc "The stable key whose active pointer this version may replace."
  @spec identity(version :: t()) :: {asset_type(), scope(), String.t() | nil}
  def identity(%__MODULE__{} = version) do
    owner =
      case version.scope do
        :tenant -> version.tenant_id
        scope when scope in [:project, :task, :session] -> version.project_id
        _global -> nil
      end

    {version.type, version.scope, owner}
  end

  defp known(value, values, name) do
    if value in values, do: :ok, else: {:error, {:invalid_asset_field, name, value}}
  end

  defp validate_identity(:tenant, %{tenant_id: id}) when is_binary(id) and id != "", do: :ok

  defp validate_identity(scope, %{project_id: id})
       when scope in [:project, :task, :session] and is_binary(id) and id != "",
       do: :ok

  defp validate_identity(scope, _attrs) when scope in [:tenant, :project, :task, :session],
    do: {:error, {:missing_scope_owner, scope}}

  defp validate_identity(_scope, _attrs), do: :ok

  defp validate_content(content) when is_binary(content), do: :ok
  defp validate_content(content) when is_map(content) or is_list(content), do: :ok
  defp validate_content(_content), do: {:error, :invalid_asset_content}

  defp validate_safety(safety) when is_map(safety), do: :ok
  defp validate_safety(_safety), do: {:error, :invalid_safety_constraints}

  defp encode_content(content) when is_binary(content), do: content
  defp encode_content(content), do: JSON.encode!(content)

  defp digest(type, layer, scope, content, safety) do
    payload = %{
      "type" => Atom.to_string(type),
      "layer" => Atom.to_string(layer),
      "scope" => Atom.to_string(scope),
      "content" => content,
      "safety" => safety
    }

    :sha256
    |> :crypto.hash(JSON.encode!(payload))
    |> Base.encode16(case: :lower)
  end

  defp approximate_tokens(encoded), do: div(byte_size(encoded) + 3, 4)
end

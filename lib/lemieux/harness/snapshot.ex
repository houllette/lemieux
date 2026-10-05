defmodule Lemieux.Harness.Snapshot do
  @moduledoc """
  The complete effective, provider-neutral harness used by a model request.

  `Lemieux.RequestSnapshot` answers what was sent to one model call. This
  object answers the wider question: which resolved assets, visible tools,
  host profiles, limits, and runtime versions made the loop behave that way.
  It is built after request hooks run, so a resume or fork records the
  configuration actually used now rather than copying a parent's claim.

  Two digests serve different purposes. `semantic_sha256` excludes identity
  and opaque correlations, allowing behavior-equivalent runs to group safely.
  `manifest_sha256` covers the complete object, including those correlations,
  so an audit record remains tamper-evident without pretending a tenant or run
  id changes model behavior.
  """

  alias Lemieux.Contract
  alias Lemieux.Harness.Safe
  alias Lemieux.Request
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor

  @version 1
  @behavior_fields ~w(resolved_assets system_prompt_sha256 model effort request_params
                      context_limits tools hooks workflow compaction environment_context
                      sandbox_profile runtime)

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          semantic_sha256: String.t(),
          manifest_sha256: String.t(),
          resolved_assets: [map()],
          system_prompt_sha256: String.t(),
          model: String.t(),
          effort: String.t() | nil,
          request_params: map(),
          context_limits: map(),
          tools: map(),
          hooks: map(),
          workflow: map(),
          compaction: map(),
          environment_context: map(),
          sandbox_profile: map(),
          runtime: map(),
          correlations: map(),
          extensions: map()
        }

  @enforce_keys [
    :id,
    :semantic_sha256,
    :manifest_sha256,
    :resolved_assets,
    :system_prompt_sha256,
    :model,
    :request_params,
    :context_limits,
    :tools,
    :hooks,
    :workflow,
    :compaction,
    :environment_context,
    :sandbox_profile,
    :runtime,
    :correlations,
    :extensions
  ]
  defstruct schema_version: @version,
            id: nil,
            semantic_sha256: nil,
            manifest_sha256: nil,
            resolved_assets: [],
            system_prompt_sha256: nil,
            model: nil,
            effort: nil,
            request_params: %{},
            context_limits: %{},
            tools: %{},
            hooks: %{},
            workflow: %{},
            compaction: %{},
            environment_context: %{},
            sandbox_profile: %{},
            runtime: %{},
            correlations: %{},
            extensions: %{}

  @doc "Builds a snapshot from an effective request and host-supplied identifiers."
  @spec build(request :: Request.t(), opts :: keyword()) :: t()
  def build(%Request{} = request, opts \\ []) do
    descriptors = Enum.map(request.tools, &tool_descriptor/1)
    descriptor_bytes = JSON.encode!(descriptors)

    attrs = %{
      "id" => Keyword.get(opts, :id, "harness_" <> Lemieux.ID.generate()),
      "resolved_assets" => Keyword.get(opts, :resolved_assets, []),
      "system_prompt_sha256" => Contract.sha256(request.system || ""),
      "model" => request.model,
      "effort" => effort(request.params),
      "request_params" => Safe.request_params(request.params),
      "context_limits" => Keyword.get(opts, :context_limits, %{}),
      "tools" => %{
        "profile" => Keyword.get(opts, :tool_profile, %{}),
        "descriptors" => descriptors,
        "sha256" => Contract.sha256(descriptor_bytes)
      },
      "hooks" => Keyword.get(opts, :hooks, %{}),
      "workflow" => Keyword.get(opts, :workflow, %{}),
      "compaction" => Keyword.get(opts, :compaction, %{}),
      "environment_context" => Keyword.get(opts, :environment_context, %{}),
      "sandbox_profile" => Keyword.get(opts, :sandbox_profile, %{}),
      "runtime" => %{
        "lemieux_version" => Lemieux.version(),
        "req_llm_version" => dependency_version(:req_llm)
      },
      "correlations" => Keyword.get(opts, :correlations, %{}),
      "extensions" => Keyword.get(opts, :extensions, %{})
    }

    {:ok, snapshot} = new(attrs)
    snapshot
  end

  @doc "Builds a validated snapshot from JSON-shaped attributes."
  @spec new(attrs :: map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    attrs = Contract.json(attrs)

    with :ok <- required_behavior(attrs),
         :ok <- validate_assets(attrs["resolved_assets"]),
         :ok <- validate_digest(attrs["system_prompt_sha256"], "system_prompt_sha256"),
         :ok <- nonempty(attrs["model"], "model"),
         :ok <- maps(attrs) do
      base =
        attrs
        |> Map.take(@behavior_fields ++ ~w(id correlations extensions))
        |> Map.put_new("id", "harness_" <> Lemieux.ID.generate())
        |> Map.put_new("effort", nil)
        |> Map.put_new("correlations", %{})
        |> Map.put_new("extensions", %{})
        |> Map.put("schema_version", @version)

      semantic = semantic_digest(base)

      wire =
        base
        |> Map.put("semantic_sha256", semantic)
        |> then(&Map.put(&1, "manifest_sha256", Contract.digest(&1)))

      with :ok <- supplied_digest(attrs, "semantic_sha256", semantic),
           :ok <- supplied_digest(attrs, "manifest_sha256", wire["manifest_sha256"]) do
        {:ok, from_verified_map(wire)}
      end
    end
  end

  def new(_attrs), do: {:error, :invalid_harness_snapshot}

  @doc "Returns the stable behavior digest."
  @spec digest(snapshot :: t()) :: String.t()
  def digest(%__MODULE__{} = snapshot), do: snapshot.semantic_sha256

  @doc "Returns the JSON-shaped snapshot."
  @spec to_map(snapshot :: t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    %{
      "schema_version" => snapshot.schema_version,
      "id" => snapshot.id,
      "semantic_sha256" => snapshot.semantic_sha256,
      "manifest_sha256" => snapshot.manifest_sha256,
      "resolved_assets" => snapshot.resolved_assets,
      "system_prompt_sha256" => snapshot.system_prompt_sha256,
      "model" => snapshot.model,
      "effort" => snapshot.effort,
      "request_params" => snapshot.request_params,
      "context_limits" => snapshot.context_limits,
      "tools" => snapshot.tools,
      "hooks" => snapshot.hooks,
      "workflow" => snapshot.workflow,
      "compaction" => snapshot.compaction,
      "environment_context" => snapshot.environment_context,
      "sandbox_profile" => snapshot.sandbox_profile,
      "runtime" => snapshot.runtime,
      "correlations" => snapshot.correlations,
      "extensions" => snapshot.extensions
    }
  end

  @doc "Encodes the canonical wire representation."
  @spec encode!(snapshot :: t()) :: String.t()
  def encode!(%__MODULE__{} = snapshot), do: snapshot |> to_map() |> Contract.encode!()

  @doc "Decodes and verifies a snapshot."
  @spec decode(json :: String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, map} <- Contract.decode(json),
         :ok <- Contract.verify_version(map, "schema_version", @version),
         :ok <- verify(map) do
      new(map)
    end
  end

  @doc "Verifies version and both semantic and complete-manifest digests."
  @spec verify(snapshot_or_map :: t() | map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = snapshot), do: snapshot |> to_map() |> verify()

  def verify(map) when is_map(map) do
    with :ok <- Contract.verify_version(map, "schema_version", @version),
         expected when is_binary(expected) <- Map.get(map, "semantic_sha256"),
         true <- expected == semantic_digest(map),
         :ok <- Contract.verify_digest(map, "manifest_sha256") do
      :ok
    else
      false -> {:error, :semantic_digest_mismatch}
      nil -> {:error, :missing_semantic_digest}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_other), do: {:error, :invalid_harness_snapshot}

  defp semantic_digest(map) do
    Contract.digest(map, ~w(id correlations semantic_sha256 manifest_sha256))
  end

  defp tool_descriptor(tool) do
    descriptor = tool |> Tool.descriptor() |> Descriptor.to_map()

    %{
      "name" => Tool.name(tool),
      "description" => Tool.description(tool),
      "schema" => Tool.schema(tool),
      "descriptor" => descriptor
    }
  end

  defp effort(params) do
    case Keyword.get(params, :reasoning_effort) do
      nil -> nil
      :default -> nil
      "default" -> nil
      value -> to_string(value)
    end
  end

  defp dependency_version(app) do
    case Application.spec(app, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp required_behavior(attrs) do
    case Enum.find(@behavior_fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:missing_field, field}}
    end
  end

  defp validate_assets(assets) when is_list(assets) do
    case Enum.find(assets, fn
           %{"id" => id, "sha256" => digest}
           when is_binary(id) and id != "" and is_binary(digest) and byte_size(digest) == 64 ->
             false

           _invalid ->
             true
         end) do
      nil -> :ok
      invalid -> {:error, {:invalid_resolved_asset, invalid}}
    end
  end

  defp validate_assets(_assets), do: {:error, :invalid_resolved_assets}

  defp validate_digest(value, _field) when is_binary(value) and byte_size(value) == 64, do: :ok
  defp validate_digest(_value, field), do: {:error, {:invalid_digest, field}}

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(_value, field), do: {:error, {:invalid_field, field}}

  defp maps(attrs) do
    fields =
      ~w(request_params context_limits tools hooks workflow compaction environment_context
         sandbox_profile runtime correlations extensions)

    case Enum.find(fields, &(not is_map(Map.get(attrs, &1, %{})))) do
      nil -> :ok
      field -> {:error, {:invalid_field, field}}
    end
  end

  defp supplied_digest(attrs, key, calculated) do
    case Map.get(attrs, key) do
      nil -> :ok
      ^calculated -> :ok
      _other -> {:error, {:supplied_digest_mismatch, key}}
    end
  end

  defp from_verified_map(map) do
    %__MODULE__{
      id: map["id"],
      semantic_sha256: map["semantic_sha256"],
      manifest_sha256: map["manifest_sha256"],
      resolved_assets: map["resolved_assets"],
      system_prompt_sha256: map["system_prompt_sha256"],
      model: map["model"],
      effort: map["effort"],
      request_params: map["request_params"],
      context_limits: map["context_limits"],
      tools: map["tools"],
      hooks: map["hooks"],
      workflow: map["workflow"],
      compaction: map["compaction"],
      environment_context: map["environment_context"],
      sandbox_profile: map["sandbox_profile"],
      runtime: map["runtime"],
      correlations: map["correlations"],
      extensions: map["extensions"]
    }
  end
end

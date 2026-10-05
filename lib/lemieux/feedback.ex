defmodule Lemieux.Feedback do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Immutable, anchored human feedback and its append-only interpretations.

  Feedback is deliberately not a transcript entry. A complaint is evidence
  about a run, not another instruction to the active agent; putting it in the
  conversation would change resume/replay behavior and let the agent act before
  a regression case had been frozen. Hosts persist revisions of this struct in
  a `Lemieux.Feedback.Store` and keep the original `raw_text` unchanged.

  Construction requires tenant, project and session provenance plus at least
  one concrete run/entry/tool/artifact anchor. This module validates the wire
  shape; the host remains responsible for resolving those opaque identifiers
  under its own authorization boundary.
  """

  alias Lemieux.ID

  @version 1
  @types ~w(bug missed_requirement product_requirement style_preference taste unknown)a
  @scopes ~w(task project tenant global)a
  @verifiability ~w(mechanical environmental human_review subjective_judge unknown)a
  @durabilities ~w(one_off standing_rule)a
  @statuses ~w(captured triaged needs_clarification non_experimental case_draft closed)a
  @anchor_fields ~w(run_id entry_id tool_call_id artifact)

  @type feedback_type ::
          :bug
          | :missed_requirement
          | :product_requirement
          | :style_preference
          | :taste
          | :unknown
  @type scope :: :task | :project | :tenant | :global
  @type verifiability_class ::
          :mechanical | :environmental | :human_review | :subjective_judge | :unknown
  @type durability :: :one_off | :standing_rule
  @type status ::
          :captured | :triaged | :needs_clarification | :non_experimental | :case_draft | :closed

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          revision: pos_integer(),
          created_at: DateTime.t(),
          actor: map(),
          raw_text: String.t(),
          provenance: map(),
          type: feedback_type(),
          scope: scope(),
          verifiability: map(),
          durability: durability(),
          status: status(),
          interpretations: [map()],
          audit: map()
        }

  @enforce_keys [:id, :created_at, :actor, :raw_text, :provenance]
  defstruct schema_version: @version,
            id: nil,
            revision: 1,
            created_at: nil,
            actor: nil,
            raw_text: nil,
            provenance: nil,
            type: :unknown,
            scope: :project,
            verifiability: %{"class" => "unknown"},
            durability: :one_off,
            status: :captured,
            interpretations: [],
            audit: %{"supersedes" => nil, "redactions" => []}

  @doc "Builds a feedback record after validating its anchor and routing fields."
  @spec new(raw_text :: String.t(), provenance :: map(), opts :: keyword()) ::
          {:ok, t()} | {:error, term()}
  def new(raw_text, provenance, opts \\ [])

  def new(raw_text, provenance, opts)
      when is_binary(raw_text) and is_map(provenance) and is_list(opts) do
    type = Keyword.get(opts, :type, :unknown)
    scope = Keyword.get(opts, :scope, :project)
    durability = Keyword.get(opts, :durability, :one_off)
    status = Keyword.get(opts, :status, :captured)
    verifiability = Keyword.get(opts, :verifiability, %{"class" => "unknown"})

    with :ok <- nonempty(raw_text, :raw_text),
         :ok <- validate_provenance(provenance),
         :ok <- enum(type, @types, :type),
         :ok <- enum(scope, @scopes, :scope),
         :ok <- enum(durability, @durabilities, :durability),
         :ok <- enum(status, @statuses, :status),
         :ok <- validate_verifiability(verifiability),
         {:ok, actor} <- actor(Keyword.get(opts, :actor)),
         {:ok, audit} <- audit(Keyword.get(opts, :audit)) do
      {:ok,
       %__MODULE__{
         id: Keyword.get(opts, :id, "fb_" <> ID.generate()),
         revision: Keyword.get(opts, :revision, 1),
         created_at: Keyword.get_lazy(opts, :created_at, &DateTime.utc_now/0),
         actor: actor,
         raw_text: raw_text,
         provenance: provenance,
         type: type,
         scope: scope,
         verifiability: verifiability,
         durability: durability,
         status: status,
         interpretations: Keyword.get(opts, :interpretations, []),
         audit: audit
       }}
    end
  end

  def new(_raw_text, _provenance, _opts), do: {:error, :invalid_feedback}

  @doc "Appends one interpretation while preserving the observed feedback."
  @spec revise(feedback :: t(), interpretation :: map(), opts :: keyword()) ::
          {:ok, t()} | {:error, term()}
  def revise(%__MODULE__{} = feedback, interpretation, opts \\ [])
      when is_map(interpretation) and is_list(opts) do
    questions = Map.get(interpretation, "questions_asked", 0)
    type = Keyword.get(opts, :type, feedback.type)
    scope = Keyword.get(opts, :scope, feedback.scope)
    durability = Keyword.get(opts, :durability, feedback.durability)
    status = Keyword.get(opts, :status, feedback.status)
    verifiability = Keyword.get(opts, :verifiability, feedback.verifiability)

    with :ok <- question_count(questions),
         :ok <- enum(type, @types, :type),
         :ok <- enum(scope, @scopes, :scope),
         :ok <- enum(durability, @durabilities, :durability),
         :ok <- enum(status, @statuses, :status),
         :ok <- validate_verifiability(verifiability) do
      revision = Map.put(interpretation, "revision", feedback.revision + 1)

      {:ok,
       %{
         feedback
         | revision: feedback.revision + 1,
           type: type,
           scope: scope,
           durability: durability,
           status: status,
           verifiability: verifiability,
           interpretations: feedback.interpretations ++ [revision]
       }}
    end
  end

  @doc "Returns the classified verifiability value."
  @spec verifiability_class(feedback :: t()) :: verifiability_class()
  def verifiability_class(%__MODULE__{verifiability: %{"class" => class}}) do
    String.to_existing_atom(class)
  end

  @doc "Encodes one feedback revision as versioned JSON."
  @spec encode!(feedback :: t()) :: String.t()
  def encode!(%__MODULE__{} = feedback), do: feedback |> to_map() |> JSON.encode!()

  @doc "Decodes and validates one feedback revision."
  @spec decode!(json :: String.t()) :: t()
  def decode!(json) when is_binary(json), do: json |> JSON.decode!() |> from_map!()

  @doc "Returns the JSON-shaped representation used by feedback stores and hosts."
  @spec to_map(feedback :: t()) :: map()
  def to_map(%__MODULE__{} = feedback) do
    %{
      "schema_version" => feedback.schema_version,
      "id" => feedback.id,
      "revision" => feedback.revision,
      "created_at" => DateTime.to_iso8601(feedback.created_at),
      "actor" => feedback.actor,
      "raw_text" => feedback.raw_text,
      "provenance" => feedback.provenance,
      "type" => Atom.to_string(feedback.type),
      "scope" => Atom.to_string(feedback.scope),
      "verifiability" => feedback.verifiability,
      "durability" => Atom.to_string(feedback.durability),
      "status" => Atom.to_string(feedback.status),
      "interpretations" => feedback.interpretations,
      "audit" => feedback.audit
    }
  end

  @doc false
  @spec from_map!(map()) :: t()
  def from_map!(%{"schema_version" => @version} = map) do
    opts = [
      id: Map.fetch!(map, "id"),
      revision: Map.fetch!(map, "revision"),
      created_at: parse_time!(Map.fetch!(map, "created_at")),
      actor: Map.fetch!(map, "actor"),
      type: decode_enum!(Map.fetch!(map, "type"), @types, :type),
      scope: decode_enum!(Map.fetch!(map, "scope"), @scopes, :scope),
      verifiability: Map.fetch!(map, "verifiability"),
      durability: decode_enum!(Map.fetch!(map, "durability"), @durabilities, :durability),
      status: decode_enum!(Map.fetch!(map, "status"), @statuses, :status),
      interpretations: Map.get(map, "interpretations", []),
      audit: Map.get(map, "audit", %{"supersedes" => nil, "redactions" => []})
    ]

    case new(Map.fetch!(map, "raw_text"), Map.fetch!(map, "provenance"), opts) do
      {:ok, feedback} -> feedback
      {:error, reason} -> raise ArgumentError, "invalid feedback: #{inspect(reason)}"
    end
  end

  def from_map!(%{"schema_version" => version}) do
    raise ArgumentError, "unsupported feedback schema version #{inspect(version)}"
  end

  def from_map!(_map), do: raise(ArgumentError, "feedback is missing its schema version")

  defp validate_provenance(provenance) do
    required = ~w(host tenant_id project_id session_id)
    missing = Enum.reject(required, &nonempty_value?(Map.get(provenance, &1)))
    anchors = Enum.filter(@anchor_fields, &anchor?(Map.get(provenance, &1)))

    cond do
      missing != [] -> {:error, {:missing_provenance, missing}}
      anchors == [] -> {:error, {:missing_anchor, @anchor_fields}}
      true -> :ok
    end
  end

  defp anchor?(%{"kind" => kind, "id" => id}), do: nonempty_value?(kind) and nonempty_value?(id)
  defp anchor?(value), do: nonempty_value?(value)

  defp validate_verifiability(%{"class" => class}) when is_binary(class) do
    case Map.fetch(Map.new(@verifiability, &{Atom.to_string(&1), &1}), class) do
      {:ok, _class} -> :ok
      :error -> {:error, {:invalid_verifiability, class}}
    end
  end

  defp validate_verifiability(_value), do: {:error, :invalid_verifiability}

  defp actor(nil), do: {:ok, %{"type" => "human", "id" => "local"}}
  defp actor(actor) when is_map(actor), do: {:ok, actor}
  defp actor(_actor), do: {:error, :invalid_actor}

  defp audit(nil), do: {:ok, %{"supersedes" => nil, "redactions" => []}}
  defp audit(audit) when is_map(audit), do: {:ok, audit}
  defp audit(_audit), do: {:error, :invalid_audit}

  defp question_count(count) when is_integer(count) and count in 0..3, do: :ok

  defp question_count(count) when is_integer(count) and count > 3,
    do: {:error, :too_many_questions}

  defp question_count(_count), do: {:error, :invalid_question_count}

  defp enum(value, values, name) do
    if value in values, do: :ok, else: {:error, {invalid_name(name), value}}
  end

  defp decode_enum!(value, values, name) do
    mapping = Map.new(values, &{Atom.to_string(&1), &1})

    case Map.fetch(mapping, value) do
      {:ok, decoded} -> decoded
      :error -> raise ArgumentError, "invalid feedback #{name} #{inspect(value)}"
    end
  end

  defp nonempty(value, _name) when is_binary(value) and value != "", do: :ok
  defp nonempty(_value, name), do: {:error, {invalid_name(name), name}}
  defp nonempty_value?(value), do: is_binary(value) and value != ""

  defp invalid_name(:type), do: :invalid_type
  defp invalid_name(:scope), do: :invalid_scope
  defp invalid_name(:durability), do: :invalid_durability
  defp invalid_name(:status), do: :invalid_status
  defp invalid_name(:raw_text), do: :invalid_raw_text

  defp parse_time!(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> time
      _invalid -> raise ArgumentError, "invalid feedback timestamp #{inspect(value)}"
    end
  end
end

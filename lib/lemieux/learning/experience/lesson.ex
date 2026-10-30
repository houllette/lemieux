defmodule Lemieux.Learning.Experience.Lesson do
  @moduledoc """
  **Experimental.** Not part of the stable public API.
  An immutable, scoped lesson with its complete authorized source bytes.

  A lesson records an observation and hypothesis, never an activation grant.
  `qualification` is either `unconfirmed` or `behavioral`: even adoption or a
  passing source evaluation cannot establish transfer to another task/model.
  Confirmation and runtime promotion remain separate host-owned contracts.

  `new/3` accepts an authorized `Lemieux.Learning.Experience.Bundle`, artifact
  bytes keyed by SHA-256, and JSON-shaped attributes. The two MiB wire limit
  includes the embedded bundle and base64 artifact bytes. A complete source
  graph and conservative case-exposure closure travel with the lesson, so
  pruning its original campaign cannot silently erase its provenance.

  Bindings require model, tool/environment digests and repository identity.
  Workspace facts additionally require revision and source digests. Hosts
  supply current identities to `applicable/3`; missing/changed bindings and
  expired records are never current facts. No serialized value is executed.
  """

  alias Lemieux.Contract
  alias Lemieux.Learning.Experience.Bundle
  alias Lemieux.Learning.Experience.Lesson.Sources

  @version 1
  @max_bytes 2 * 1024 * 1024
  @fields ~w(schema_version id sha256 scope key kind outcome qualification applicability mechanism supporting contradicting candidate_ids binding provenance created_at expires_at supersedes experience artifacts source_case_ids source_lessons)a
  @attrs ~w(key kind outcome qualification applicability mechanism supporting contradicting candidate_ids binding provenance created_at expires_at supersedes source_lessons)
  @bindings ~w(model tools_sha256 environment_sha256 repository)
  @kinds ~w(workspace_fact procedure proposer_lesson)
  @outcomes ~w(supported rejected contradicted insufficient_evidence)

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          sha256: String.t(),
          scope: map(),
          key: String.t(),
          kind: String.t(),
          outcome: String.t(),
          qualification: String.t(),
          applicability: [String.t()],
          mechanism: String.t(),
          supporting: [String.t()],
          contradicting: [String.t()],
          candidate_ids: [String.t()],
          binding: map(),
          provenance: map(),
          created_at: String.t(),
          expires_at: String.t() | nil,
          supersedes: [String.t()],
          experience: map(),
          artifacts: map(),
          source_case_ids: [String.t()],
          source_lessons: [map()]
        }
  defstruct @fields

  @doc "Builds a lesson only after verifying all source bytes and ancestry."
  @spec new(bundle :: Bundle.t(), artifacts :: map(), attrs :: map()) ::
          {:ok, t()} | {:error, term()}
  def new(%Bundle{} = bundle, artifacts, attrs) when is_map(artifacts) and is_map(attrs) do
    with :ok <- input_size(artifacts, attrs),
         :ok <- bounded(Bundle.to_map(bundle)),
         true <- Enum.all?(Map.keys(attrs), &(&1 in @attrs)),
         {:ok, prior} <- source_lessons(Map.get(attrs, "source_lessons", []), bundle.scope, 0),
         {:ok, sources} <- Sources.verify(Bundle.to_map(bundle), artifacts) do
      base =
        Map.merge(attrs, %{
          "schema_version" => @version,
          "scope" => bundle.scope,
          "experience" => Bundle.to_map(bundle),
          "artifacts" => Map.new(artifacts, fn {sha, bytes} -> {sha, Base.encode64(bytes)} end),
          "source_case_ids" => Enum.sort(Enum.uniq(sources.cases ++ prior.cases)),
          "source_lessons" => Map.get(attrs, "source_lessons", [])
        })

      digest = Contract.digest(base)
      base |> Map.merge(%{"id" => "lesson_" <> digest, "sha256" => digest}) |> from_map()
    else
      false -> {:error, :unknown_lesson_field}
      error -> error
    end
  end

  def new(_bundle, _artifacts, _attrs), do: {:error, :invalid_lesson}

  @doc "Returns the complete wire manifest, including retained source bytes."
  @spec to_map(lesson :: t()) :: map()
  def to_map(%__MODULE__{} = lesson) do
    Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(lesson, &1)})
  end

  @doc "Encodes a lesson. Use `decode/1` to validate an external encoding."
  @spec encode!(lesson :: t()) :: String.t()
  def encode!(%__MODULE__{} = lesson), do: lesson |> to_map() |> Contract.encode!()

  @doc "Decodes bounded bytes and verifies the schema, complete digest and sources."
  @spec decode(bytes :: binary()) :: {:ok, t()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, map} <- Contract.decode(bytes), do: from_map(map)
  end

  def decode(bytes) when is_binary(bytes), do: {:error, :lesson_too_large}
  def decode(_bytes), do: {:error, :invalid_lesson}

  @doc "Revalidates a lesson, including embedded sources."
  @spec verify(lesson :: t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = lesson) do
    case lesson |> to_map() |> from_map() do
      {:ok, _lesson} -> :ok
      error -> error
    end
  end

  @doc "Checks current host identities and expiry without changing qualification."
  @spec applicable(lesson :: t(), context :: map(), now :: DateTime.t()) :: :ok | {:error, term()}
  def applicable(%__MODULE__{} = lesson, context, %DateTime{} = now) when is_map(context) do
    cond do
      not is_nil(lesson.expires_at) and DateTime.compare(now, time!(lesson.expires_at)) != :lt ->
        {:error, :expired}

      DateTime.compare(now, time!(lesson.created_at)) == :lt ->
        {:error, :not_yet_created}

      true ->
        binding_matches(lesson.binding, context)
    end
  end

  defp from_map(map, depth \\ 0)
  defp from_map(_map, depth) when depth > 8, do: {:error, :lesson_ancestry_limit}

  defp from_map(map, depth) do
    with :ok <- bounded(map),
         :ok <- Contract.verify_version(map, "schema_version", @version),
         :ok <- digest(map),
         :ok <- fields(map),
         {:ok, prior} <- source_lessons(map["source_lessons"], map["scope"], depth),
         {:ok, artifacts} <- artifact_bytes(map["artifacts"]),
         {:ok, sources} <- Sources.verify(map["experience"], artifacts),
         true <- map["scope"] == map["experience"]["scope"],
         true <- map["source_case_ids"] == Enum.sort(Enum.uniq(sources.cases ++ prior.cases)),
         true <- Enum.all?(map["supersedes"], &(&1 in prior.ids)),
         true <- Enum.all?(map["candidate_ids"], &(&1 in sources.candidates)),
         true <-
           Enum.all?(
             map["supporting"] ++ map["contradicting"],
             &(&1 in (sources.observations ++ prior.ids))
           ) do
      {:ok, struct!(__MODULE__, Map.new(@fields, &{&1, map[Atom.to_string(&1)]}))}
    else
      false -> {:error, :inconsistent_lesson_sources}
      error -> error
    end
  end

  defp source_lessons(values, scope, depth) when is_list(values) and length(values) <= 16 do
    Enum.reduce_while(values, {:ok, %{ids: [], cases: []}}, fn value, {:ok, prior} ->
      with true <- is_map(value),
           {:ok, lesson} <- from_map(value, depth + 1),
           true <- lesson.scope == scope and lesson.id not in prior.ids do
        {:cont,
         {:ok, %{ids: [lesson.id | prior.ids], cases: lesson.source_case_ids ++ prior.cases}}}
      else
        _invalid -> {:halt, {:error, :invalid_source_lesson}}
      end
    end)
  end

  defp source_lessons(_values, _scope, _depth), do: {:error, :invalid_source_lesson}

  defp digest(%{"id" => id, "sha256" => sha} = map) when is_binary(sha) do
    if id == "lesson_" <> sha and Contract.digest(map, ["id", "sha256"]) == sha,
      do: :ok,
      else: {:error, :digest_mismatch}
  end

  defp digest(_map), do: {:error, :missing_digest}

  defp fields(map) do
    known = Enum.map(@fields, &Atom.to_string/1)

    required_lists =
      ~w(applicability supporting contradicting candidate_ids supersedes source_case_ids)

    with true <- Enum.sort(Map.keys(map)) == Enum.sort(known),
         true <- nonempty?(map["key"]) and nonempty?(map["mechanism"]),
         true <- map["kind"] in @kinds and map["outcome"] in @outcomes,
         true <- map["qualification"] in ~w(unconfirmed behavioral),
         true <- Enum.all?(required_lists, &ids?(map[&1])),
         true <- map["applicability"] != [] and map["supporting"] ++ map["contradicting"] != [],
         true <- map["outcome"] != "supported" or map["supporting"] != [],
         true <- Enum.all?(map["supersedes"], &valid_id?/1),
         true <- is_map(map["provenance"]) and nonempty?(map["provenance"]["actor"]),
         :ok <- binding(map["kind"], map["binding"]),
         :ok <- timestamps(map) do
      :ok
    else
      _invalid -> {:error, :invalid_lesson_fields}
    end
  end

  defp binding(kind, binding) when is_map(binding) do
    allowed = @bindings ++ ~w(revision source_sha256)
    required = if kind == "workspace_fact", do: allowed, else: @bindings

    if Enum.all?(Map.keys(binding), &(&1 in allowed)) and
         Enum.all?(required, &nonempty?(binding[&1])) and
         Enum.all?(~w(tools_sha256 environment_sha256 source_sha256), &valid_digest?(binding[&1])) and
         Enum.all?(binding, fn {_key, value} -> nonempty?(value) end),
       do: :ok,
       else: {:error, :invalid_lesson_binding}
  end

  defp binding(_kind, _binding), do: {:error, :invalid_lesson_binding}

  defp valid_digest?(nil), do: true
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)

  defp binding_matches(binding, context) do
    case Enum.find(Enum.sort(binding), fn {key, value} -> context[key] != value end) do
      nil -> :ok
      {key, _value} -> {:error, {:binding_changed, key}}
    end
  end

  defp timestamps(%{"created_at" => created, "expires_at" => expires}) do
    with {:ok, start, 0} <- parse_time(created),
         true <- is_nil(expires) or later?(expires, start) do
      :ok
    else
      _invalid -> {:error, :invalid_lesson_timestamp}
    end
  end

  defp timestamps(_map), do: {:error, :invalid_lesson_timestamp}

  defp later?(expires, start) do
    case parse_time(expires) do
      {:ok, finish, 0} -> DateTime.compare(finish, start) == :gt
      _invalid -> false
    end
  end

  defp parse_time(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp parse_time(_value), do: {:error, :invalid_time}
  defp time!(value), do: value |> DateTime.from_iso8601() |> elem(1)

  defp artifact_bytes(encoded) when is_map(encoded) do
    Enum.reduce_while(encoded, {:ok, %{}}, fn {digest, value}, {:ok, bytes} ->
      with true <- is_binary(digest) and is_binary(value),
           {:ok, decoded} <- Base.decode64(value),
           true <- Contract.sha256(decoded) == digest do
        {:cont, {:ok, Map.put(bytes, digest, decoded)}}
      else
        _invalid -> {:halt, {:error, :invalid_lesson_artifact_bytes}}
      end
    end)
  end

  defp artifact_bytes(_value), do: {:error, :invalid_lesson_artifact_bytes}

  defp input_size(artifacts, attrs) do
    if Enum.all?(artifacts, fn {key, bytes} -> is_binary(key) and is_binary(bytes) end) and
         Enum.sum(Enum.map(artifacts, fn {_key, bytes} -> byte_size(bytes) end)) <= @max_bytes,
       do: bounded(attrs),
       else: {:error, :lesson_too_large}
  end

  defp bounded(map) do
    if json?(map) and byte_size(JSON.encode!(map)) <= @max_bytes,
      do: :ok,
      else: {:error, :lesson_too_large}
  end

  defp json?(%_struct{}), do: false

  defp json?(map) when is_map(map),
    do: Enum.all?(map, fn {k, v} -> is_binary(k) and String.valid?(k) and json?(v) end)

  defp json?(list) when is_list(list), do: Enum.all?(list, &json?/1)
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value), do: is_number(value) or is_boolean(value) or is_nil(value)

  defp ids?(values),
    do: is_list(values) and Enum.all?(values, &nonempty?/1) and Enum.uniq(values) == values

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_id?(value), do: is_binary(value) and Regex.match?(~r/\Alesson_[a-f0-9]{64}\z/, value)
end

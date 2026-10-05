defmodule Lemieux.Subagent.Result do
  @moduledoc """
  The standard terminal envelope returned by one delegated investigator.

  The child supplies only the research body. Runtime-owned identity, status,
  definition provenance, usage, and transcript reference are added after the
  session finishes, so a model cannot claim success or attribute work to a
  different definition. Full transcripts remain in the store; this envelope
  is deliberately bounded before it is inserted into the parent context.

  ## What the envelope refuses to throw away

  The 2026-09-17 investigator evaluation measured what strictness cost: 28 of
  63 GLM children and 5 of 59 Luna children came back `failed` *after reading
  the right files*. Nineteen answered in prose or a fenced block instead of
  the JSON object; nine were rejected on envelope shape because a `read`-only
  child cannot compute an artifact digest or a file hash it was never given a
  tool to produce. The parent saw none of those findings, and the work was
  paid for twice — once to do it and once to not receive it.

  So the body is read leniently and the strictness is moved to *labelling*
  rather than acceptance:

    * a fenced code block is unwrapped before parsing, because a model that
      was told to answer in JSON and wrapped it in Markdown answered in JSON;
    * everything but `answer` defaults, so a child that reports no artifacts
      reports no artifacts rather than failing;
    * a digest is optional wherever the child cannot compute one, and the
      absence is visible in the envelope instead of fatal;
    * an answer that is not JSON at all is kept as prose, with `format` set to
      `:prose` and an uncertainty naming the schema error.

  `format` is what keeps this honest. A prose envelope was never validated
  against the schema, and a parent reading one is reading an unstructured
  claim; saying so in the envelope is different from pretending the child
  complied, and different again from discarding what it found.
  """

  alias Lemieux.Entry
  alias Lemieux.Subagent.Definition
  alias Lemieux.Usage

  # Three scouts in one session on 2026-09-18 each wrote a 14–22 KB analysis and
  # each was clipped to twelve, labelled as having answered outside the
  # schema, and then cut again to fit the parent's tool-result budget. Thirty-two is
  # above what a long investigation writes, and the group renderer keeps three of
  # them inside the default `tool_output_bytes`.
  @max_answer_bytes 32 * 1024
  @statuses [:ok, :failed, :timeout, :cancelled, :budget_exhausted]
  @confidences ~w(low medium high)

  @type status :: :ok | :failed | :timeout | :cancelled | :budget_exhausted
  @typedoc "Whether the body satisfied the schema, or was kept as prose."
  @type format :: :structured | :prose
  @type t :: %__MODULE__{
          child_id: String.t(),
          definition_id: String.t(),
          definition_digest: String.t(),
          status: status(),
          format: format(),
          answer: String.t(),
          findings: [map()],
          artifacts: [map()],
          uncertainties: [String.t()],
          coverage: map(),
          acceptance: map() | nil,
          usage: map(),
          transcript_id: String.t()
        }

  @enforce_keys [
    :child_id,
    :definition_id,
    :definition_digest,
    :status,
    :answer,
    :transcript_id
  ]
  defstruct child_id: nil,
            definition_id: nil,
            definition_digest: nil,
            status: nil,
            # `:structured` when the body satisfied the definition's schema,
            # `:prose` when it did not and was kept anyway. Never inferred by
            # a reader from an empty findings list: a child can legitimately
            # report no findings in a valid envelope.
            format: :structured,
            answer: nil,
            findings: [],
            artifacts: [],
            uncertainties: [],
            coverage: %{"searched" => [], "skipped" => []},
            acceptance: nil,
            usage: %{},
            transcript_id: nil

  @doc "The structured-output schema a child model is asked to satisfy."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      # Only the answer is required. Asking a `read`-only child for artifact
      # digests it has no tool to compute produced rejected envelopes, not
      # better evidence.
      "required" => ~w(answer),
      "properties" => %{
        "answer" => %{"type" => "string", "maxLength" => @max_answer_bytes},
        "findings" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ~w(claim confidence evidence),
            "properties" => %{
              "claim" => %{"type" => "string"},
              "confidence" => %{"type" => "string", "enum" => @confidences},
              "evidence" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ~w(ref locator),
                  "properties" => %{
                    "ref" => %{"type" => "string"},
                    "locator" => %{"type" => "string"},
                    "digest" => %{"type" => ["string", "null"]}
                  }
                }
              }
            }
          }
        },
        "artifacts" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ~w(kind ref),
            "properties" => %{
              "kind" => %{"type" => "string"},
              "ref" => %{"type" => "string"},
              "digest" => %{"type" => ["string", "null"]}
            }
          }
        },
        "uncertainties" => %{"type" => "array", "items" => %{"type" => "string"}},
        "coverage" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ~w(searched skipped),
          "properties" => %{
            "searched" => %{"type" => "array", "items" => %{"type" => "string"}},
            "skipped" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        }
      }
    }
  end

  @doc """
  Decodes and validates the child-owned body.

  A fenced block is unwrapped first: a model that was asked for JSON and
  wrapped it in Markdown produced JSON, and rejecting it lost the whole
  investigation over a pair of backticks.
  """
  @spec decode(value :: String.t() | map()) :: {:ok, map()} | {:error, term()}
  def decode(value) when is_binary(value) do
    with {:ok, decoded} <- JSON.decode(unfenced(value)) do
      decode(decoded)
    end
  end

  def decode(%{} = body) do
    with {:ok, answer} <- nonempty(body["answer"], :answer),
         {:ok, findings} <- findings(body["findings"]),
         {:ok, artifacts} <- artifacts(body["artifacts"]),
         {:ok, uncertainties} <- strings(body["uncertainties"], :uncertainties),
         {:ok, coverage} <- coverage(body["coverage"]) do
      {:ok,
       %{
         answer: answer,
         findings: findings,
         artifacts: artifacts,
         uncertainties: uncertainties,
         coverage: coverage
       }}
    end
  end

  def decode(_value), do: {:error, :not_an_object}

  @doc """
  Strips one Markdown code fence from a model answer, if it has one.

  Public because a host schema wants the same courtesy: the fence is the
  commonest single reason a valid body arrives unreadable, and each schema
  re-deciding how to spot one would produce a different set of children whose
  work survives.
  """
  @spec unfenced(text :: String.t()) :: String.t()
  def unfenced(text) when is_binary(text) do
    trimmed = String.trim(text)

    case Regex.run(~r/\A```[a-zA-Z0-9_-]*\s*\n(.*?)\n?```\z/s, trimmed) do
      [_whole, inner] -> String.trim(inner)
      _unfenced -> trimmed
    end
  end

  @doc "Builds the runtime-owned terminal envelope from a finished child transcript."
  @spec from_session(
          child_id :: String.t(),
          definition :: Definition.t(),
          status :: status(),
          entries :: [Entry.t()],
          usage :: map()
        ) :: t()
  def from_session(child_id, %Definition{} = definition, status, entries, usage)
      when status in @statuses and is_list(entries) and is_map(usage) do
    base = %{
      child_id: child_id,
      definition_id: definition.id,
      definition_digest: Definition.digest(definition),
      status: status,
      usage: usage,
      transcript_id: child_id
    }

    if status == :ok do
      success(base, definition.result_schema, entries)
    else
      terminal(base, status, recorded_error(entries) || terminal_reason(status), entries)
    end
  end

  @doc "Converts an envelope to a durable JSON-shaped payload."
  @spec to_map(result :: t()) :: map()
  def to_map(%__MODULE__{} = result) do
    result
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), json(value)} end)
  end

  @doc """
  Reconstructs a persisted terminal envelope without creating atoms from data.

  `format` defaults to `:structured` when absent, which is what every envelope
  written before the field existed was: the strict decode either succeeded or
  the envelope was not `:ok` at all.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(
        %{
          "child_id" => child_id,
          "definition_id" => definition_id,
          "definition_digest" => definition_digest,
          "status" => status,
          "answer" => answer,
          "findings" => findings,
          "artifacts" => artifacts,
          "uncertainties" => uncertainties,
          "coverage" => coverage,
          "usage" => usage,
          "transcript_id" => transcript_id
        } = map
      ) do
    with {:ok, status} <- status(status),
         {:ok, format} <- format(Map.get(map, "format", "structured")),
         true <- is_nil(map["acceptance"]) or is_map(map["acceptance"]),
         true <-
           is_binary(answer) and is_list(findings) and is_list(artifacts) and
             is_list(uncertainties) and is_map(coverage) and is_map(usage) do
      {:ok,
       %__MODULE__{
         child_id: child_id,
         definition_id: definition_id,
         definition_digest: definition_digest,
         status: status,
         format: format,
         answer: answer,
         findings: findings,
         artifacts: artifacts,
         uncertainties: uncertainties,
         coverage: coverage,
         usage: usage,
         acceptance: map["acceptance"],
         transcript_id: transcript_id
       }}
    else
      false -> {:error, :invalid_persisted_result}
      {:error, _reason} = error -> error
    end
  end

  def from_map(_map), do: {:error, :invalid_persisted_result}

  @doc "Sums direct request usage in one child transcript, preserving unknown cost."
  @spec usage(entries :: [Entry.t()]) :: map()
  def usage(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(fn
      %Entry{usage: usage} when is_map(usage) -> [usage]
      _entry -> []
    end)
    |> Usage.sum()
  end

  # A child that ran out of turns or died has nothing to report; a child that
  # answered has something, whatever shape it arrived in. Only the first is
  # terminal here — `final_text/1` failing means there is no assistant message
  # at all, which is the one success path with genuinely nothing in it.
  defp success(base, schema, entries) do
    case final_text(entries) do
      {:ok, text} -> decoded(base, schema.decode(text), text)
      {:error, reason} -> terminal(base, :failed, "the child produced no answer: #{reason}")
    end
  end

  # An answer over the bound in an otherwise valid body is clipped and kept
  # structured: the findings, artifacts and coverage beside it satisfied the
  # schema, and demoting all of them to prose over the answer's length threw
  # away exactly the fields the schema exists to keep.
  defp decoded(base, {:ok, body}, _text) do
    {answer, clipped} = clip(body.answer)
    body = %{body | answer: answer, uncertainties: body.uncertainties ++ clipped}
    struct!(__MODULE__, base |> Map.merge(body) |> Map.put(:format, :structured))
  end

  # The defect the investigator evaluation exposed: this used to be `:failed`, and
  # two dozen children that had read the right files reported nothing to their
  # parent because of it. The answer is kept, labelled as unvalidated, with the
  # schema's own complaint beside it.
  defp decoded(base, {:error, reason}, text) do
    {answer, clipped} = clip(text)

    uncertainties =
      [
        "the child answered outside the result schema, so this answer was not validated: " <>
          inspect(reason)
      ] ++ clipped

    struct!(
      __MODULE__,
      Map.merge(base, %{
        format: :prose,
        answer: answer,
        findings: [],
        artifacts: [],
        uncertainties: uncertainties,
        coverage: %{"searched" => [], "skipped" => []}
      })
    )
  end

  defp clip(text) when byte_size(text) <= @max_answer_bytes, do: {text, []}

  defp clip(text) do
    {binary_slice(text, 0, @max_answer_bytes),
     ["the answer was longer than #{@max_answer_bytes} bytes and was clipped"]}
  end

  # A child stopped while it was answering still wrote something, and what it wrote
  # is kept: on 2026-09-18 three scouts in one session were each streaming a
  # complete answer when their deadline fired, and the envelope handed the parent
  # `""` for all three. The status is unchanged, so this never promotes a stopped
  # child to success. Only a pure answer turn qualifies — a last turn that also
  # called tools is narration.
  defp terminal(base, status, reason, entries \\ []) do
    {answer, cut} = unfinished(entries)

    struct!(
      __MODULE__,
      Map.merge(base, %{
        status: status,
        format: :prose,
        answer: answer,
        findings: [],
        artifacts: [],
        uncertainties: [reason | cut],
        coverage: %{"searched" => [], "skipped" => []}
      })
    )
  end

  defp unfinished(entries) do
    with %Entry{payload: payload} = last <-
           entries |> Enum.reverse() |> Enum.find(&(&1.type == :assistant)),
         [] <- List.wrap(payload["tool_calls"]),
         {:ok, text} <- assistant_text(last) do
      {answer, clipped} = clip(text)

      {answer,
       [
         "the child was stopped while answering, so this answer may be incomplete and was not validated"
       ] ++
         clipped}
    else
      _no_answer_turn -> {"", []}
    end
  end

  defp final_text(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find(&(&1.type == :assistant))
    |> assistant_text()
  end

  defp assistant_text(nil), do: {:error, "no assistant message was recorded"}

  defp assistant_text(%Entry{payload: payload}) do
    text =
      payload
      |> Map.get("content", [])
      |> Enum.filter(&(Map.get(&1, "type") == "text"))
      |> Enum.map_join(&Map.get(&1, "text", ""))

    if text == "", do: {:error, "the last assistant message was empty"}, else: {:ok, text}
  end

  defp findings(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn finding, {:ok, acc} ->
      case finding(finding) do
        {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp findings(nil), do: {:ok, []}
  defp findings(_values), do: {:error, {:invalid, :findings}}

  defp finding(%{"claim" => claim, "confidence" => confidence, "evidence" => evidence})
       when confidence in @confidences do
    with {:ok, claim} <- nonempty(claim, :claim),
         {:ok, evidence} <- evidence(evidence) do
      {:ok, %{"claim" => claim, "confidence" => confidence, "evidence" => evidence}}
    end
  end

  defp finding(_finding), do: {:error, {:invalid, :finding}}

  defp evidence(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, &evidence_item/2)
    |> reverse_ok()
  end

  defp evidence(_values), do: {:error, {:invalid, :evidence}}

  defp evidence_item(%{"ref" => ref, "locator" => locator} = item, {:ok, acc}) do
    with {:ok, ref} <- nonempty(ref, :evidence_ref),
         {:ok, locator} <- nonempty(locator, :evidence_locator),
         :ok <- optional_digest(item["digest"]) do
      {:cont, {:ok, [with_digest(%{"ref" => ref, "locator" => locator}, item["digest"]) | acc]}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp evidence_item(_item, _acc), do: {:halt, {:error, {:invalid, :evidence}}}

  # The digest is optional because a `read`-only child has no tool that
  # computes one. Demanding it rejected nine finished investigations in the
  # 2026-09-17 run; recording its absence says the same thing and keeps them.
  defp artifacts(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, &artifact/2)
    |> reverse_ok()
  end

  defp artifacts(nil), do: {:ok, []}
  defp artifacts(_values), do: {:error, {:invalid, :artifacts}}

  defp artifact(%{"kind" => kind, "ref" => ref} = artifact, {:ok, acc}) do
    with {:ok, kind} <- nonempty(kind, :artifact_kind),
         {:ok, ref} <- nonempty(ref, :artifact_ref),
         :ok <- optional_digest(artifact["digest"]) do
      {:cont, {:ok, [with_digest(%{"kind" => kind, "ref" => ref}, artifact["digest"]) | acc]}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp artifact(_artifact, _acc), do: {:halt, {:error, {:invalid, :artifacts}}}

  defp with_digest(valid, nil), do: valid
  defp with_digest(valid, digest), do: Map.put(valid, "digest", digest)

  # A child that reported no coverage reported no coverage; the empty shape is
  # the honest reading, not a reason to lose the answer beside it.
  defp coverage(%{} = partial) do
    with {:ok, searched} <- strings(partial["searched"], :coverage_searched),
         {:ok, skipped} <- strings(partial["skipped"], :coverage_skipped) do
      {:ok, %{"searched" => searched, "skipped" => skipped}}
    end
  end

  defp coverage(nil), do: {:ok, %{"searched" => [], "skipped" => []}}
  defp coverage(_coverage), do: {:error, {:invalid, :coverage}}

  defp strings(nil, _field), do: {:ok, []}

  defp strings(values, _field) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: {:error, :not_strings}
  end

  defp strings(_values, field), do: {:error, {:invalid, field}}

  defp nonempty(value, _field) when is_binary(value) and byte_size(value) > 0, do: {:ok, value}
  defp nonempty(_value, field), do: {:error, {:invalid, field}}

  defp optional_digest(nil), do: :ok
  defp optional_digest(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp optional_digest(_value), do: {:error, {:invalid, :evidence_digest}}

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error

  defp terminal_reason(:failed), do: "the child failed before returning a valid result"
  defp terminal_reason(:timeout), do: "the child exceeded its deadline"
  defp terminal_reason(:cancelled), do: "the child was cancelled"
  defp terminal_reason(:budget_exhausted), do: "the child exhausted its budget"

  defp recorded_error(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find(&(&1.type == :error))
    |> error_reason()
  end

  defp error_reason(%Entry{payload: %{"reason" => reason}})
       when is_binary(reason) and byte_size(reason) > 0,
       do: reason

  defp error_reason(_entry), do: nil

  defp status("ok"), do: {:ok, :ok}
  defp status("failed"), do: {:ok, :failed}
  defp status("timeout"), do: {:ok, :timeout}
  defp status("cancelled"), do: {:ok, :cancelled}
  defp status("budget_exhausted"), do: {:ok, :budget_exhausted}
  defp status(status), do: {:error, {:unknown_result_status, status}}

  defp format("structured"), do: {:ok, :structured}
  defp format("prose"), do: {:ok, :prose}
  defp format(format), do: {:error, {:unknown_result_format, format}}

  defp json(value) when is_nil(value) or is_boolean(value), do: value

  defp json(value) when is_atom(value), do: Atom.to_string(value)

  defp json(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json(item)} end)

  defp json(value) when is_list(value), do: Enum.map(value, &json/1)
  defp json(value), do: value
end

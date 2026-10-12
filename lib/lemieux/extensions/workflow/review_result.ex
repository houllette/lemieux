defmodule Lemieux.Extensions.Workflow.ReviewResult do
  @moduledoc false
  alias Lemieux.Session
  alias Lemieux.StructuredResult

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["summary", "findings"],
      "properties" => %{
        "summary" => %{"type" => "string"},
        "findings" => %{
          "type" => "array",
          "maxItems" => 100,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ~w(severity file line explanation evidence),
            "properties" => %{
              "severity" => %{"type" => "string", "enum" => ~w(P0 P1 P2 P3)},
              "file" => %{"type" => "string", "minLength" => 1},
              "line" => %{"type" => "integer", "minimum" => 1},
              "explanation" => %{"type" => "string", "minLength" => 1},
              "evidence" => %{
                "type" => "array",
                "minItems" => 1,
                "items" => %{"type" => "string"}
              }
            }
          }
        }
      }
    }
  end

  def record(session, workflow) do
    snapshot = Session.snapshot(session)
    entries = Enum.reverse(snapshot.entries)
    assistant = Enum.find(entries, &(&1.type == :assistant))
    prompt = Enum.find(entries, &(&1.type == :user and &1.payload["stop_hook"] != true))

    text =
      if assistant,
        do: Enum.map_join(assistant.payload["content"] || [], &Map.get(&1, "text", "")),
        else: ""

    {:ok, contract} = StructuredResult.new(schema())

    report =
      case StructuredResult.validate(contract, text) do
        {:ok, value} -> %{"status" => "validated", "value" => value}
        {:error, reason} -> %{"status" => "invalid", "reason" => Atom.to_string(reason)}
      end

    report =
      Map.merge(report, %{
        "target" => workflow["target"],
        "diff_sha256" => workflow["diff_sha256"],
        "prompt_id" => prompt && prompt.id,
        "schema_sha256" => contract.digest,
        "verification" => "model_reported"
      })

    with {:ok, document} <- Session.document(session, "lemieux.review_result"),
         {:ok, _document} <-
           Session.put_document(session, "lemieux.review_result", document.revision, report),
         do: :ok
  end
end

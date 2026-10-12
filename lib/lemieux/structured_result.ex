defmodule Lemieux.StructuredResult do
  @moduledoc """
  A bounded, local JSON Schema contract for a turn's final answer.

  Validation happens after tool execution. It cannot erase file changes or
  turn a failed/cancelled request into success. Local references are supported;
  external references and unknown schema dialects are refused before inference
  so validating an answer cannot perform an unexpected network fetch. There is
  no automatic paid repair request. Hosts decide whether to ask for a repair.
  """

  alias Lemieux.Session

  @max_bytes 48_000
  @dialects [
    "https://json-schema.org/draft/2020-12/schema",
    "http://json-schema.org/draft-07/schema#"
  ]
  @type t :: %{schema: map(), digest: String.t()}

  @doc "Checks a JSON object schema and records its identity without model calls."
  @spec new(schema :: map()) :: {:ok, t()} | {:error, atom()}
  def new(%{"type" => "object"} = schema) do
    with true <- byte_size(JSON.encode!(schema)) <= @max_bytes,
         true <- local?(schema),
         :ok <- buildable(schema) do
      digest = :crypto.hash(:sha256, JSON.encode!(schema)) |> Base.encode16(case: :lower)
      {:ok, %{schema: schema, digest: digest}}
    else
      _invalid -> {:error, :invalid_schema}
    end
  end

  def new(_schema), do: {:error, :invalid_schema}

  defp buildable(schema) do
    case ReqLLM.Schema.validate(%{}, schema) do
      {:ok, _value} -> :ok
      {:error, %{tag: :json_schema_validation_failed}} -> :ok
      _invalid -> {:error, :invalid_schema}
    end
  end

  defp local?(%{} = value) do
    Enum.all?(value, fn
      {key, ref} when key in ["$ref", "$dynamicRef", "$recursiveRef"] ->
        is_binary(ref) and String.starts_with?(ref, "#")

      {"$schema", dialect} ->
        dialect in @dialects

      {_key, nested} ->
        local?(nested)
    end)
  end

  defp local?(values) when is_list(values), do: Enum.all?(values, &local?/1)
  defp local?(_scalar), do: true

  @doc "Validates the exact final JSON text, with no fence stripping or coercion."
  @spec validate(contract :: t(), text :: String.t()) :: {:ok, map()} | {:error, atom()}
  def validate(contract, text) when is_binary(text) and byte_size(text) <= @max_bytes do
    case JSON.decode(text) do
      {:ok, value} ->
        case ReqLLM.Schema.validate(value, contract.schema) do
          {:ok, validated} -> {:ok, validated}
          {:error, _reason} -> {:error, :schema_mismatch}
        end

      {:error, _reason} ->
        {:error, :invalid_json}
    end
  end

  def validate(_contract, _text), do: {:error, :output_too_large}

  @doc "Validates a terminal outcome and checkpoints its independently named result."
  @spec finish(
          session :: Session.session(),
          contract :: t(),
          text :: String.t(),
          complete? :: boolean()
        ) :: map()
  def finish(session, contract, text, complete?) do
    result = if complete?, do: validate(contract, text), else: {:error, :incomplete_turn}

    report =
      case result do
        {:ok, value} ->
          %{"status" => "validated", "value" => value, "schema_sha256" => contract.digest}

        {:error, reason} ->
          %{
            "status" => "invalid",
            "reason" => Atom.to_string(reason),
            "schema_sha256" => contract.digest
          }
      end

    persist(session, report)
  end

  defp persist(session, report) do
    with {:ok, document} <- Session.document(session, "lemieux.structured_result"),
         {:ok, _document} <-
           Session.put_document(session, "lemieux.structured_result", document.revision, report) do
      report
    else
      _error ->
        %{
          "status" => "invalid",
          "reason" => "result_checkpoint_failed",
          "schema_sha256" => report["schema_sha256"]
        }
    end
  end
end

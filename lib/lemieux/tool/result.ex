defmodule Lemieux.Tool.Result do
  @moduledoc """
  One tool outcome, split into what the model reads and what consumers audit.

  `model_text` is the bounded, provider-facing projection. The remaining
  fields are renderer-neutral JSON data retained in the transcript for hosts,
  audit, resume and richer presentation. A standalone host can ignore every
  field except `model_text`; a richer host never has to parse prose to recover
  resource links, artifacts or a typed result.

  Tools may continue returning `{:ok, iodata}`. Returning
  `{:ok, Lemieux.Tool.Result.new(text, ...)}` opts into the structured
  contract without creating a second dispatch path.

  ## Attachments

  `attachments` are images and documents the model is shown beside
  `model_text` — a screenshot an MCP server returned, a PNG `read` opened —
  in `Lemieux.Tool.Attachment`'s shape. They are not audit evidence and are
  not in `to_map/1`: the audit budget exists to keep a transcript's record of
  a call small, and a screenshot would blow it on arrival, taking every other
  structured field with it. They have their own limits instead
  (`Lemieux.Tool.Attachment.limit/1`), applied where every result is bounded.
  `model_text` should still say what is attached: a model whose provider
  cannot carry the attachment, or a later request that no longer sends it,
  still has the text.
  """

  alias Lemieux.Tool.Attachment

  @typedoc "A renderer-neutral, transcript-safe tool result."
  @type t :: %__MODULE__{
          model_text: String.t(),
          structured_content: term() | nil,
          content: [map()],
          artifacts: [map()],
          attachments: [Attachment.t()],
          cost: map() | nil,
          metadata: map()
        }

  @enforce_keys [:model_text]
  defstruct model_text: "",
            structured_content: nil,
            content: [],
            artifacts: [],
            attachments: [],
            cost: nil,
            metadata: %{}

  @doc """
  Builds a structured result. Every non-text field must be JSON-shaped, and
  `:attachments` must be `Lemieux.Tool.Attachment` maps.
  """
  @spec new(model_text :: iodata(), opts :: keyword()) :: t()
  def new(model_text, opts \\ []) when is_list(opts) do
    result = %__MODULE__{
      model_text: model_text |> IO.iodata_to_binary() |> sanitize(),
      structured_content: Keyword.get(opts, :structured_content),
      content: Keyword.get(opts, :content, []),
      artifacts: Keyword.get(opts, :artifacts, []),
      attachments: Keyword.get(opts, :attachments, []),
      cost: Keyword.get(opts, :cost),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate!(result)
  end

  @doc """
  Applies `Lemieux.Tool.Attachment.limit/1`, naming in `model_text` whatever
  is left out.
  """
  @spec limit_attachments(result :: t()) :: t()
  def limit_attachments(%__MODULE__{attachments: []} = result), do: result

  def limit_attachments(%__MODULE__{attachments: attachments} = result) do
    case Attachment.limit(attachments) do
      {^attachments, []} ->
        result

      {kept, notes} ->
        %{result | attachments: kept, model_text: Enum.join([result.model_text | notes], "\n")}
    end
  end

  @doc "Normalises a legacy text return or leaves a structured result intact."
  @spec normalize(t() | iodata()) :: t()
  def normalize(%__MODULE__{} = result), do: validate!(result)
  def normalize(output), do: new(output)

  @doc "Returns only the optional JSON evidence carried by `result`."
  @spec to_map(result :: t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{}
    |> put_present("structured_content", result.structured_content)
    |> put_present("content", result.content)
    |> put_present("artifacts", result.artifacts)
    |> put_present("cost", result.cost)
    |> put_present("metadata", result.metadata)
  end

  @doc "Bounds the structured evidence without ever writing invalid partial JSON."
  @spec limit(result :: t(), max_bytes :: pos_integer()) :: t()
  def limit(%__MODULE__{} = result, max_bytes)
      when is_integer(max_bytes) and max_bytes > 0 do
    evidence = to_map(result)
    encoded = JSON.encode!(evidence)

    if byte_size(encoded) <= max_bytes do
      result
    else
      marker = %{
        "truncated" => true,
        "bytes" => byte_size(encoded),
        "sha256" => digest(encoded)
      }

      %{
        result
        | model_text:
            result.model_text <>
              "\n\n[structured result exceeded the #{max_bytes}-byte audit budget]",
          structured_content: marker,
          content: [],
          artifacts: [],
          cost: nil,
          metadata: %{}
      }
    end
  end

  defp validate!(%__MODULE__{} = result) do
    if is_binary(result.model_text) and valid_shapes?(result) and valid_values?(result) do
      result
    else
      raise ArgumentError, "tool result fields must be valid JSON values"
    end
  end

  defp valid_shapes?(result) do
    is_list(result.content) and Enum.all?(result.content, &is_map/1) and
      is_list(result.artifacts) and Enum.all?(result.artifacts, &is_map/1) and
      is_list(result.attachments) and Enum.all?(result.attachments, &Attachment.valid?/1) and
      (is_nil(result.cost) or is_map(result.cost)) and is_map(result.metadata)
  end

  defp valid_values?(result) do
    [
      result.structured_content,
      result.content,
      result.artifacts,
      result.attachments,
      result.cost,
      result.metadata
    ]
    |> Enum.all?(&json_safe?/1)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, _key, value) when value == %{}, do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp json_safe?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_safe?(value) when is_list(value), do: Enum.all?(value, &json_safe?/1)

  defp json_safe?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_safe?(nested) end)
  end

  defp json_safe?(_value), do: false

  defp sanitize(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text)
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

defimpl String.Chars, for: Lemieux.Tool.Result do
  def to_string(result), do: result.model_text
end

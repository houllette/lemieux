defmodule Lemieux.Request do
  @moduledoc """
  One model request, described in lemieux's own terms.

  ## Why the messages are entries

  The obvious design is a list of provider-shaped messages built up as the
  conversation goes. This carries the transcript instead — the same
  `Lemieux.Entry` structs that are on disk — and leaves the translation into
  provider messages to the provider implementation.

  That choice is what makes resume and replay honest rather than approximate.
  A resumed session builds its request from entries read back out of the
  store; a live session builds its request from entries it just wrote. If the
  request were assembled from some other in-memory conversation state, those
  two paths would be different code, and "resume continues exactly where it
  left off" would be a claim nobody could check. Here it is one function of
  one list, and the check is that the lists are equal.

  It also keeps the loop free of provider vocabulary: `Lemieux.Turn` and
  `Lemieux.Session` never mention a message format, so a test double at this
  seam is a few lines rather than a mock of somebody else's struct.

  ## Fields

    * `model` — a `req_llm` model specification, like
      `"anthropic:claude-sonnet-4-5"`, or `"ixway:ID"` with the optional
      Ixway integration. A string rather than a struct so it
      survives a config file, a CLI flag and a database column unchanged.
    * `system` — the system prompt, or `nil`.
    * `entries` — the transcript to send, oldest first. Entries that carry no
      message (a cancellation, say) are dropped by the provider.
    * `tools` — the tools the model may call.
    * `context` — ephemeral host correlation identifiers, kept out of generation params.
    * `params` — provider-neutral generation parameters (`:temperature`,
      `:max_tokens`, …) passed through to `req_llm`.
    * `output_schema` — an optional req_llm structured-output schema. It uses
      the same provider seam as text and tool requests; no provider-specific
      response mode enters the loop.
  """

  alias Lemieux.Entry
  alias Lemieux.Reference

  @type t :: %__MODULE__{
          model: String.t(),
          system: String.t() | nil,
          entries: [Entry.t()],
          tools: [Lemieux.Tool.t()],
          context: map(),
          params: keyword(),
          output_schema: term() | nil
        }

  @enforce_keys [:model]
  defstruct context: %{},
            model: nil,
            system: nil,
            entries: [],
            tools: [],
            params: [],
            output_schema: nil

  @doc """
  Builds a request.
  """
  @spec new(model :: String.t(), opts :: keyword()) :: t()
  def new(model, opts \\ []) when is_binary(model) do
    struct!(%__MODULE__{model: model}, opts)
  end

  # The entry types a provider turns into messages. `entries` also carries the
  # session's own records — every earlier request's snapshot among them, each
  # holding the whole system prompt and tool catalog — which the provider
  # drops. Counted, they made the compaction forecast grow with the number of
  # requests rather than with the conversation: thirty one-line tool calls
  # forecast 120k tokens, and a local model compacted away files it had just
  # read at a third of its fallback window.
  @sent_types [:user, :system, :assistant, :tool_result]

  @doc "Returns the encoded size of the provider-neutral input used for forecasting."
  @spec input_bytes(request :: t()) :: pos_integer()
  def input_bytes(%__MODULE__{} = request) do
    %{
      "system" => request.system,
      "entries" =>
        request.entries
        |> Enum.filter(&(&1.type in @sent_types))
        |> Enum.map(&%{"type" => &1.type, "payload" => Reference.estimable(&1.payload)}),
      "tools" =>
        Enum.map(request.tools, fn tool ->
          %{
            "name" => Lemieux.Tool.name(tool),
            "description" => Lemieux.Tool.description(tool),
            "schema" => Lemieux.Tool.schema(tool)
          }
        end)
    }
    |> JSON.encode!()
    |> byte_size()
    |> max(1)
  end

  @doc "Returns a pessimistic, provider-neutral token weight for admission."
  @spec estimated_tokens(request :: t()) :: pos_integer()
  def estimated_tokens(%__MODULE__{} = request) do
    max(input_bytes(request) + Keyword.get(request.params, :max_tokens, 0), 1)
  end
end

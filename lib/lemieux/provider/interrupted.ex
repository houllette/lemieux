defmodule Lemieux.Provider.Interrupted do
  @moduledoc """
  A stream the provider ended before the answer was complete.

  `req_llm` returns a typed exception for most failures, but two ways a
  generation can die arrive looking like success. An OpenAI-compatible server
  that fails mid-answer sends an `error` event inside a `200` stream, which
  `req_llm` turns into a response whose finish reason is `:error`. Anthropic
  sends `event: error` (`overloaded_error`, for one) and closes the stream,
  which `req_llm`'s decoder skips, so the response simply ends without the
  `message_delta`/`message_stop` every complete Anthropic answer carries.

  Reported as a finish, either one is a truncated answer written into the
  transcript as if it were whole, with nothing for a retry to act on. So the
  adapter raises this instead: a typed, retryable failure that
  `Lemieux.Provider.Error` classifies as `:server`, the same as a `5xx` —
  the provider broke off, and asking again is the ordinary remedy.

  `detail` is the provider's own sentence when it sent one. `finish_reason` is
  what the stream reported, `nil` when it stopped without saying.
  """

  defexception [:provider, :finish_reason, :detail, retryable: true]

  @type t :: %__MODULE__{
          provider: String.t() | nil,
          finish_reason: atom() | nil,
          detail: String.t() | nil,
          retryable: boolean()
        }

  @impl true
  def message(%__MODULE__{detail: detail}) when is_binary(detail) and detail != "",
    do: "the provider ended the stream before the answer was complete: " <> detail

  def message(%__MODULE__{}),
    do: "the provider ended the stream before the answer was complete"
end

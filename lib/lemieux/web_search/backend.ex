defmodule Lemieux.WebSearch.Backend do
  @moduledoc """
  Host-owned web-search transport behind the model-facing search tool.

  A backend owns endpoints, credentials and vendor response parsing. The
  library tool owns the stable input schema, normalization, safety caps and
  model-facing output. Keeping that line means an embedder can use a hosted
  API, a private metasearch service or a deterministic test double without
  putting provider branches in the agent loop.

  Backend state is executable host state. It may contain credentials and must
  be supplied again when a session is resumed; Lemieux never serializes it.
  Error strings are model-visible and therefore must already be safe to show.
  """

  alias Lemieux.WebSearch.Result

  @typedoc "Non-secret, JSON-shaped request and cost evidence."
  @type usage :: %{optional(String.t()) => term()}

  @callback search(
              state :: term(),
              query :: String.t(),
              opts :: keyword()
            ) :: {:ok, [Result.t()], usage()} | {:error, term()}
end

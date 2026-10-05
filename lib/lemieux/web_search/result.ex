defmodule Lemieux.WebSearch.Result do
  @moduledoc """
  One provider-neutral web-search result.

  Backends construct this shape; `Lemieux.Tools.WebSearch` validates and
  bounds it before anything reaches a model or transcript.
  """

  @type t :: %__MODULE__{
          title: String.t(),
          url: String.t(),
          snippet: String.t(),
          published_at: DateTime.t() | nil
        }

  @enforce_keys [:title, :url, :snippet]
  defstruct [:title, :url, :snippet, :published_at]
end

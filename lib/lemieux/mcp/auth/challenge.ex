defmodule Lemieux.MCP.Auth.Challenge do
  @moduledoc """
  What a server said when it refused the request.

  A `401` (or a `403` asking for more scope) carries a `WWW-Authenticate`
  header, and everything the client does next is decided by what is in it: the
  URL of the protected-resource metadata, the scopes the server considers
  necessary, and whether this is a first authorization or a step up from one
  that already happened.

  ## Both fields are optional in practice

  The specification says a server **must** implement one of two discovery
  mechanisms, and naming `resource_metadata` in the challenge is only one of
  them. Atlassian's MCP server, measured, answers

      WWW-Authenticate: Bearer realm="OAuth", error="invalid_token", error_description="..."

  with no `resource_metadata` at all. So a challenge that names nothing is
  ordinary, not malformed, and the caller falls back to the well-known URIs —
  see `Lemieux.MCP.Auth.Discovery`.

  ## Scopes here outrank scopes anywhere else

  The specification is explicit that a client **must** treat the scopes in the
  challenge as authoritative for the current operation, and **must not** assume
  any relationship between them and the `scopes_supported` in the metadata.
  They are not necessarily a subset. They are what this request needs.

  ## The parsing

  RFC 7235's `auth-param` list, which is a comma-separated list of `name=value`
  where the value may be a quoted string — and a quoted string may contain a
  comma, which is why this is a small parser rather than `String.split/2`. Real
  servers do put commas in `error_description`.
  """

  @typedoc """
  A parsed challenge. Every field may be absent, because every field is
  optional in something a real server sends.
  """
  @type t :: %__MODULE__{
          scheme: String.t() | nil,
          resource_metadata: String.t() | nil,
          scopes: [String.t()],
          error: String.t() | nil,
          error_description: String.t() | nil
        }

  defstruct scheme: nil, resource_metadata: nil, scopes: [], error: nil, error_description: nil

  @doc """
  Parses a `WWW-Authenticate` header value.

  `nil` — no header at all — parses to an empty challenge rather than an error:
  a server may refuse without saying why, and the caller still has the
  well-known URIs to try.
  """
  @spec parse(header :: String.t() | nil) :: t()
  def parse(nil), do: %__MODULE__{}

  def parse(header) when is_binary(header) do
    {scheme, rest} = split_scheme(header)
    params = params(rest)

    %__MODULE__{
      scheme: scheme,
      resource_metadata: params["resource_metadata"],
      scopes: scopes(params["scope"]),
      error: params["error"],
      error_description: params["error_description"]
    }
  end

  defp split_scheme(header) do
    case String.split(String.trim(header), " ", parts: 2) do
      [scheme, rest] -> {String.downcase(scheme), rest}
      [scheme] -> {String.downcase(scheme), ""}
    end
  end

  defp scopes(nil), do: []
  defp scopes(scope), do: scope |> String.split(" ", trim: true)

  # Walks the string once, tracking whether it is inside a quoted value, so a
  # comma in an `error_description` does not end the parameter.
  defp params(rest), do: rest |> split_params() |> Map.new(&param/1)

  defp split_params(rest), do: split_params(rest, "", [], false)

  defp split_params("", current, acc, _quoted), do: Enum.reverse([current | acc])

  defp split_params(<<?\\, char, tail::binary>>, current, acc, true),
    do: split_params(tail, current <> <<?\\, char>>, acc, true)

  defp split_params(<<?", tail::binary>>, current, acc, quoted),
    do: split_params(tail, current <> ~s("), acc, not quoted)

  defp split_params(<<?,, tail::binary>>, current, acc, false),
    do: split_params(tail, "", [current | acc], false)

  defp split_params(<<char, tail::binary>>, current, acc, quoted),
    do: split_params(tail, current <> <<char>>, acc, quoted)

  defp param(chunk) do
    case String.split(chunk, "=", parts: 2) do
      [name, value] -> {name |> String.trim() |> String.downcase(), unquote_value(value)}
      [name] -> {name |> String.trim() |> String.downcase(), ""}
    end
  end

  defp unquote_value(value) do
    value
    |> String.trim()
    |> case do
      <<?", inner::binary>> -> String.replace_suffix(inner, ~s("), "")
      other -> other
    end
    |> String.replace(~S(\"), ~s("))
  end

  @doc """
  Whether this challenge asks for more scope on an existing authorization.

  Distinct from a first authorization because the answer is different: a step
  up must ask for the *union* of what was already granted and what is being
  demanded now, or authorizing for the second operation silently gives up the
  first.
  """
  @spec step_up?(challenge :: t()) :: boolean()
  def step_up?(%__MODULE__{error: "insufficient_scope"}), do: true
  def step_up?(%__MODULE__{}), do: false
end

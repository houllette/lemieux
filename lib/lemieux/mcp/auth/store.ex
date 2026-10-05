defmodule Lemieux.MCP.Auth.Store do
  @moduledoc """
  Where credentials for MCP servers are kept.

  A store is a `{module, state}` pair, the same shape and for the same reason
  as `Lemieux.Store`: the core takes no database dependency, `lmx` wants a
  file it can `chmod`, and a host with somewhere better — a keychain, a secrets
  table, a vault — implements the behaviour and puts them there.

  ## Two keys, not one

  There are two kinds of record here and they are keyed differently, which is
  the part worth getting right:

    * a **client registration** belongs to one authorization server. The
      specification is explicit that client identifiers are unique to the
      server that issued them, and that a client **must not** reuse credentials
      across authorization servers. So: keyed by `issuer`.
    * an **access token** belongs to one authorization server *and* one
      resource. RFC 8707 binds a token to the resource it was minted for, and
      one authorization server can front several — `https://github.com/login/oauth`
      does. Two MCP servers behind one authorization server must not share a
      token. So: keyed by both.

  Collapsing those into one key is the mistake this documentation exists to
  prevent, because it fails silently: everything works until the day a second
  server appears behind an issuer you already have a token for, and then a
  credential goes somewhere it was not issued for.

  ## The record carries its own issuer

  `put_token/4` stamps `issuer` and `resource` into the record as well as into
  the key. That is redundant on purpose. The MCP TypeScript SDK documents
  losing the issuer by rebuilding the token object field by field on save, and
  then being unable to tell whose token it was holding; a record that names its
  own issuer cannot be orphaned by a careless copy.

  ## Why the behaviour is three callbacks and not seven

  A host implementing this should have to write `fetch`, `put` and `delete`
  over an opaque string key — not learn lemieux's keying rules and reimplement
  them. The rules live here, in `token_key/2` and `client_key/1`, so there is
  one place they can be wrong and one place to correct them.
  """

  @typedoc "An implementation module paired with its own state."
  @type t :: {module(), state :: term()}

  @typedoc "An opaque key. Built by `token_key/2` or `client_key/1`; never parsed."
  @type key :: String.t()

  @doc """
  Reads a record, or `:error` when there is none.

  A record that was never written is `:error` rather than an error tuple: not
  being authorized yet is the ordinary case, not a fault.
  """
  @callback fetch(state :: term(), key :: key()) :: {:ok, map()} | :error

  @doc """
  Writes a record, replacing any record under the same key.
  """
  @callback put(state :: term(), key :: key(), record :: map()) :: :ok | {:error, String.t()}

  @doc """
  Removes a record. Removing one that is not there is `:ok`.
  """
  @callback delete(state :: term(), key :: key()) :: :ok | {:error, String.t()}

  @doc """
  The key an access token for `resource`, issued by `issuer`, is filed under.
  """
  @spec token_key(issuer :: String.t(), resource :: String.t()) :: key()
  def token_key(issuer, resource), do: "token\n#{issuer}\n#{resource}"

  @doc """
  The key a client registration with `issuer` is filed under.
  """
  @spec client_key(issuer :: String.t()) :: key()
  def client_key(issuer), do: "client\n#{issuer}"

  @doc """
  Reads the token held for a resource at an authorization server.
  """
  @spec fetch_token(store :: t(), issuer :: String.t(), resource :: String.t()) ::
          {:ok, map()} | :error
  def fetch_token({module, state}, issuer, resource),
    do: module.fetch(state, token_key(issuer, resource))

  @doc """
  Writes the token held for a resource at an authorization server.
  """
  @spec put_token(store :: t(), issuer :: String.t(), resource :: String.t(), token :: map()) ::
          :ok | {:error, String.t()}
  def put_token({module, state}, issuer, resource, token) do
    record = Map.merge(token, %{"issuer" => issuer, "resource" => resource})

    module.put(state, token_key(issuer, resource), record)
  end

  @doc """
  Forgets the token held for a resource.

  What a failed refresh does, and it matters that it happens: a dead token left
  in the store is retried on every run for as long as the file exists.
  """
  @spec delete_token(store :: t(), issuer :: String.t(), resource :: String.t()) ::
          :ok | {:error, String.t()}
  def delete_token({module, state}, issuer, resource),
    do: module.delete(state, token_key(issuer, resource))

  @doc """
  Reads the client registration held with an authorization server.
  """
  @spec fetch_client(store :: t(), issuer :: String.t()) :: {:ok, map()} | :error
  def fetch_client({module, state}, issuer), do: module.fetch(state, client_key(issuer))

  @doc """
  Writes the client registration held with an authorization server.
  """
  @spec put_client(store :: t(), issuer :: String.t(), client :: map()) ::
          :ok | {:error, String.t()}
  def put_client({module, state}, issuer, client),
    do: module.put(state, client_key(issuer), Map.put(client, "issuer", issuer))
end

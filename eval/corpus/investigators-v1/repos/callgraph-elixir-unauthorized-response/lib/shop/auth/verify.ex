defmodule Shop.Auth.Verify do
  @moduledoc "Verifies the bearer token on API requests."

  import Plug.Conn

  alias Shop.Auth.Responses
  alias Shop.Auth.Token

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Token.decode(raw) do
      assign(conn, :claims, claims)
    else
      {:error, reason} -> conn |> Responses.unauthorized(reason) |> halt()
      _missing -> conn |> Responses.unauthorized(:missing_token) |> halt()
    end
  end
end

defmodule Shop.Errors do
  @moduledoc "Shared error responses for the admin pipeline."

  import Plug.Conn

  def unauthorized(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "unauthorized")
  end

  def forbidden(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "forbidden")
  end
end

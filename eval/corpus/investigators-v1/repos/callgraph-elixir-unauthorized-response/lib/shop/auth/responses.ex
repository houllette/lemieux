defmodule Shop.Auth.Responses do
  @moduledoc "Error responses emitted by the API authentication plug."

  import Plug.Conn

  def unauthorized(conn, reason) do
    body = JSON.encode!(%{"error" => "unauthorized", "reason" => to_string(reason)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
  end
end

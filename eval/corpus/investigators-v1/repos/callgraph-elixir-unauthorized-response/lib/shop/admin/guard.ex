defmodule Shop.Admin.Guard do
  @moduledoc "Session-cookie check for the admin pipeline."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.cookies["admin_session"] do
      nil -> conn |> Shop.Errors.unauthorized() |> halt()
      _session -> conn
    end
  end
end

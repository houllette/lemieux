defmodule LemieuxComputerUse.Fixture do
  @moduledoc "Local browser fixture. Contains no account access, external resources or purchases."
  @spec start() :: {:ok, pid(), String.t()}
  def start do
    root = Application.app_dir(:lemieux_computer_use, "priv/fixture") |> String.to_charlist()

    {:ok, server} =
      :inets.start(:httpd,
        port: 0,
        bind_address: {127, 0, 0, 1},
        server_name: ~c"lemieux-browser-fixture",
        server_root: root,
        document_root: root,
        modules: [:mod_alias, :mod_get, :mod_head],
        mime_types: [{~c"html", ~c"text/html"}]
      )

    port = :httpd.info(server)[:port]
    {:ok, server, "http://127.0.0.1:#{port}/index.html"}
  end

  @spec stop(server :: pid()) :: :ok | {:error, term()}
  def stop(server), do: :inets.stop(:httpd, server)

  @spec goal() :: String.t()
  def goal,
    do:
      "Open the hotel finder. Search for Lisbon, select Design style, enable Free cancellation, and open Casa Flora. Stop when its details are visible."

  @spec verified?(page :: map()) :: boolean()
  def verified?(page),
    do:
      String.ends_with?(page["url"], "#casa-flora") and
        String.contains?(page["text"], "Verified selection: Lisbon | Design | free cancellation")
end

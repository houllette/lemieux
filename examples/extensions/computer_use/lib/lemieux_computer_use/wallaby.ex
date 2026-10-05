defmodule LemieuxComputerUse.Wallaby do
  @moduledoc """
  Headless Wallaby driver with one script call per bounded observation.

  The process opening a session owns it for the entire run. Wallaby monitors
  that process and closes its browser when it dies, including cancellation.
  Host startup calls `start/1` explicitly; extension assembly never starts it.

  Commands use observed node references and native WebDriver input. A failure
  after input starts is uncertain and is never automatically replayed. The
  DOM reader covers ordinary HTML/ARIA controls; frames, shadow DOM, canvas,
  uploads and multiple tabs are intentionally outside this experiment.
  """
  @behaviour LemieuxComputerUse.Driver

  @spec start(opts :: keyword()) :: :ok | {:error, term()}
  def start(opts \\ []) do
    Application.put_env(:wallaby, :driver, Wallaby.Chrome)
    Application.put_env(:wallaby, :js_logger, nil)
    Application.put_env(:wallaby, :js_errors, false)

    chrome =
      []
      |> put(:binary, Keyword.get(opts, :chrome_binary) || System.get_env("LMX_BROWSER_CHROME"))
      |> put(
        :path,
        Keyword.get(opts, :chromedriver) || System.get_env("LMX_BROWSER_CHROMEDRIVER")
      )

    Application.put_env(:wallaby, :chromedriver, chrome)

    case Application.ensure_all_started(:wallaby) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :wallaby_start_failed}
    end
  end

  @impl true
  def open(url, _opts) do
    # Do not inherit Wallaby's test defaults (--no-sandbox, an obsolete user
    # agent and automatic dialog acceptance). Each run gets a fresh profile.
    capabilities = %{
      chromeOptions: %{
        args: ["--headless", "--window-size=1280,900", "--disable-background-networking"]
      },
      unhandledPromptBehavior: "dismiss and notify"
    }

    capabilities =
      case Application.get_env(:wallaby, :chromedriver, [])[:binary] do
        nil -> capabilities
        binary -> put_in(capabilities, [:chromeOptions, :binary], binary)
      end

    case Wallaby.start_session(capabilities: capabilities) do
      {:ok, session} ->
        case boundary(fn -> Wallaby.Browser.visit(session, url) end) do
          {:ok, _} ->
            {:ok, session}

          {:error, _} = error ->
            close(session)
            error
        end

      _ ->
        {:error, "Could not open browser session"}
    end
  end

  @impl true
  def observe(session) do
    case script(session, "observe", %{}) do
      {:ok, %{"actions" => actions} = page} when is_list(actions) -> {:ok, page}
      _ -> {:error, "Could not observe browser page"}
    end
  end

  @impl true
  def act(session, page, action, text) do
    args = %{"page" => Map.take(page, ~w(document url form_state)), "action" => action}

    case script(session, "resolve", args) do
      {:ok, %{"stale" => true}} -> {:error, :stale}
      {:ok, %{"element" => reference}} -> native(session, reference, action, text)
      {:ok, %{"scrolled" => true}} -> :ok
      _ -> {:error, "Browser action was not confirmed; inspect before retrying"}
    end
  end

  @impl true
  def close(session), do: Wallaby.end_session(session)

  @doc "Returns a bounded rendered document projection for the fetch extension."
  @spec document(session :: term(), opts :: keyword()) :: {:ok, map()} | {:error, String.t()}
  def document(session, opts) do
    source = File.read!(Application.app_dir(:lemieux_computer_use, "priv/fetch.js"))

    case boundary(fn ->
           session.driver.execute_script(session, source, [Keyword.fetch!(opts, :max_bytes)])
         end) do
      {:ok, {:ok, %{"html" => _, "url" => _} = document}} -> {:ok, document}
      _ -> {:error, "Could not read rendered document"}
    end
  end

  defp native(session, reference, action, text) do
    id = reference["element-6066-11e4-a52e-4f735466cecf"] || reference["ELEMENT"]

    element = %Wallaby.Element{
      id: id,
      driver: session.driver,
      session_url: session.session_url,
      url: session.session_url <> "/element/" <> id
    }

    case boundary(fn -> input(element, action, text) end) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "Browser input outcome is uncertain; no automatic retry"}
    end
  end

  defp input(element, %{"operation" => "CLICK"}, _), do: Wallaby.Element.click(element)

  defp input(element, %{"operation" => "TYPE_TEXT"}, text),
    do: Wallaby.Element.fill_in(element, with: text)

  # An option node is observed and resolved just like a button. Native clicking
  # preserves select/input semantics instead of assigning a value in JavaScript.
  defp input(element, %{"operation" => "SELECT"}, _), do: Wallaby.Element.click(element)

  defp script(session, command, args) do
    path = Application.app_dir(:lemieux_computer_use, "priv/browser.js")

    case boundary(fn ->
           session.driver.execute_script(session, File.read!(path), [command, args])
         end) do
      {:ok, {:ok, value}} -> {:ok, value}
      _ -> {:error, "Browser script failed"}
    end
  end

  # WebDriver exceptions are an external execution boundary. Their messages
  # may contain page data, URLs or typed text, so expose a fixed error only.
  defp boundary(fun) do
    {:ok, fun.()}
  rescue
    _ -> {:error, "Browser operation failed"}
  end

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)
end

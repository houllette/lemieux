defmodule Lemieux.CLI.UpdateCheck do
  @moduledoc """
  Update notices for the `lmx` terminal host running from a source checkout.

  A source checkout updates through Git, explicitly: `/update` fetches the
  configured upstream and fast-forwards (`Lemieux.CLI.SourceUpdate`). It
  checks nothing on its own at startup. A Hex release notice would point a
  checkout at the wrong way to update, and a development tree would contact
  hex.pm every time it started. The installed binary has its own check
  against the project's GitHub releases, which installs only releases whose
  signature verifies (`Lmx.Update`).

  `fetch/1`, `check/1` and `notify/3` read the `lemieux` package's latest
  stable version from Hex, for hosts that want a version notice; `lmx` does
  not call them. They belong to the host either way: an embedded Lemieux
  session never makes a network request on its own.
  """

  @package_url "https://hex.pm/api/packages/lemieux"
  @connect_timeout 500
  @receive_timeout 1_500

  alias Lemieux.CLI.SourceUpdate

  @type get ::
          (url :: String.t(), opts :: keyword() ->
             {:ok, Req.Response.t()} | {:error, term()})

  @doc "Whether this TUI launch should check Hex. `LMX_CHECK_UPDATES=0` disables it."
  @spec enabled?(opts :: keyword()) :: boolean()
  def enabled?(opts \\ []) do
    case Keyword.fetch(opts, :check_updates) do
      {:ok, enabled?} -> enabled? != false
      :error -> System.get_env("LMX_CHECK_UPDATES") != "0"
    end
  end

  @doc """
  Explicit Git updates for source TUIs, sharing the update scheduler.

  No automatic check (`check?: false`, and a `check` that reports current
  without a request); see the module documentation.
  """
  @spec host(task_supervisor :: atom() | pid(), opts :: keyword()) :: map()
  def host(task_supervisor, opts \\ []) do
    %{
      tasks: task_supervisor,
      auto?: false,
      check?: false,
      install?: true,
      request: fn -> SourceUpdate.check(opts) end,
      request_notice: "Checking the source checkout's Git upstream…",
      stage: fn info -> {:ok, %{info: info}} end,
      stage_notice: "Preparing the Git update…",
      apply: fn %{info: info}, _app -> SourceUpdate.apply(info, opts) end,
      apply_notice: "Updating the source checkout…",
      restart_notice: &SourceUpdate.restart_notice/1,
      error_notice: &SourceUpdate.error_notice/1,
      check: fn -> :current end
    }
  end

  @doc "Checks in the host's task supervisor and sends a notice only when newer."
  @spec notify(recipient :: pid(), task_supervisor :: atom() | pid(), opts :: keyword()) :: :ok
  def notify(recipient, task_supervisor, opts \\ []) do
    if enabled?(opts) do
      Task.Supervisor.start_child(task_supervisor, fn -> deliver(recipient, opts) end)
    end

    :ok
  end

  @doc "A warning for a newer stable Hex release, or `nil`."
  @spec check(opts :: keyword()) :: String.t() | nil
  def check(opts \\ []) do
    case fetch(opts) do
      {:ok, latest} -> upgrade_notice(Lemieux.version(), latest)
      :error -> nil
    end
  end

  defp deliver(recipient, opts) do
    case check(opts) do
      nil -> :ok
      notice -> send(recipient, {:version_notice, notice})
    end
  end

  @doc "Reads the latest stable release from Hex without raising on network failure."
  @spec fetch(opts :: keyword()) :: {:ok, String.t()} | :error
  def fetch(opts \\ []) do
    get = Keyword.get(opts, :get, &Req.get/2)

    case get.(@package_url, request_options()) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "name" => "lemieux",
           "repository" => "hexpm",
           "meta" => %{"links" => %{"GitHub" => "https://github.com/houllette/lemieux"}},
           "latest_stable_version" => latest
         }
       }}
      when is_binary(latest) ->
        {:ok, latest}

      _unavailable ->
        :error
    end
  rescue
    _boundary_error -> :error
  catch
    _kind, _reason -> :error
  end

  @doc "Formats a notice only when the published version is newer."
  @spec upgrade_notice(installed :: String.t(), latest :: String.t()) :: String.t() | nil
  def upgrade_notice(installed, latest) do
    with {:ok, installed_version} <- Version.parse(installed),
         {:ok, latest_version} <- Version.parse(latest),
         [] <- latest_version.pre,
         :gt <- Version.compare(latest_version, installed_version) do
      "Lemieux v#{latest} is available (running v#{installed}); see https://hex.pm/packages/lemieux"
    else
      _not_newer -> nil
    end
  end

  defp request_options do
    [
      headers: [
        {"accept", "application/json"},
        {"user-agent", "lemieux/#{Lemieux.version()}"}
      ],
      retry: false,
      receive_timeout: @receive_timeout,
      connect_options: [timeout: @connect_timeout]
    ]
  end
end

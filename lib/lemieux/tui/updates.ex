if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Updates do
    @moduledoc """
    Host supplied asynchronous update effects. The screen owns the idle gate;
    the host owns downloads, installation and compatibility. It never loads
    modules or writes installation files itself. Input is paused only during
    activation, so a new turn cannot race code replacement. Downloads can run
    while a turn is active; activation waits for startup, queued prompts and
    session switching to finish.

    Startup and each successful session switch request a check. One timer per
    screen checks hourly, even during long turns; checks never overlap download
    or activation tasks. Repeated periodic notices for the same version stay
    quiet. Hosts opt in by supplying callbacks; the library starts no network
    traffic on its own. A host can supply `request` for explicit checks that
    differ from periodic checks, plus progress, error and restart notices.
    Every notice goes to the notice box (`Lemieux.TUI.Notices`): an update is
    news about `lmx`, not part of the conversation.

    A check may also answer `{:unverified, version, reason}`: a newer release
    exists but the host could not verify it (the installed `lmx` checks an
    Ed25519 signature over the release manifest). That is never staged, even
    with automatic installation on, and unlike a failed check it is said even
    when nobody asked, because it can mean a tampered release. The host's
    `unverified_notice` callback words it; a host's `error_notice` may return
    `nil` to keep this module's default wording.

    `announced` remembers the last verdict said about a release, `{version,
    :available}` or `{version, reason}`, rather than only its version. A
    periodic check that finds the same verdict again stays quiet, but a
    changed one is news: a release that verifies after an unsigned check is
    announced as available, and one that stops verifying is warned about
    again. Remembering versions alone let an unverified 0.2.0 swallow the
    later "0.2.0 is available" notice, so with automatic installation off
    nobody heard about the update at all.
    """

    alias Lemieux.TUI
    alias Lemieux.TUI.Notices

    @type t :: %{
            host: map() | nil,
            phase: atom(),
            task: Task.t() | nil,
            pending: term(),
            requested?: boolean(),
            timer: {reference(), reference()} | nil,
            announced: {version :: String.t(), verdict :: :available | term()} | nil,
            installed: String.t() | nil
          }

    @doc false
    @spec new(host :: map() | nil) :: t()
    def new(host),
      do: %{
        host: host,
        phase: :idle,
        task: nil,
        pending: nil,
        requested?: false,
        timer: nil,
        announced: nil,
        installed: nil
      }

    @doc false
    @spec start(state :: TUI.t()) :: TUI.t()
    def start(state) do
      state = put_in(state.status.update.announced, nil)
      state = if state.status.update.installed, do: restart_notice(state), else: state
      state = schedule(state)
      if automatic?(state), do: send(self(), :check_update)
      state
    end

    @doc false
    @spec stop(state :: TUI.t()) :: :ok
    def stop(state) do
      if state.status.update.timer do
        {_token, timer} = state.status.update.timer
        Process.cancel_timer(timer)
      end

      :ok
    end

    @doc false
    @spec poll(state :: TUI.t(), token :: reference()) :: TUI.t()
    def poll(%{status: %{update: %{timer: {token, _timer}}}} = state, token) do
      state = schedule(state)
      if automatic?(state), do: check(state), else: state
    end

    def poll(state, _token), do: state

    defp schedule(state) do
      stop(state)

      timer =
        if automatic?(state) do
          token = make_ref()
          {token, Process.send_after(self(), {:update_check, token}, 3_600_000)}
        end

      put_in(state.status.update.timer, timer)
    end

    defp automatic?(%{status: %{update: %{host: nil}}}), do: false

    defp automatic?(state),
      do: Map.get(state.status.update.host, :check?, System.get_env("LMX_CHECK_UPDATES") != "0")

    @doc false
    @spec request(state :: TUI.t()) :: TUI.t()
    def request(%{status: %{update: %{host: nil}}} = state),
      do:
        Notices.say(
          state,
          :warning,
          "This host does not provide update installation callbacks."
        )

    def request(%{status: %{update: %{host: %{install?: false}}}} = state),
      do:
        Notices.say(
          state,
          :info,
          "This host supports update checks only. Update through its installation manager."
        )

    def request(%{status: %{update: %{phase: :restart}}} = state),
      do:
        state
        |> restart_notice()
        |> put_in([Access.key!(:status), :update, :requested?], true)
        |> request_check()

    def request(%{status: %{update: %{phase: phase}}} = state)
        when phase not in [:idle, :available, :staged],
        do: Notices.say(state, :info, "An update is already in progress.")

    def request(%{status: %{update: %{host: %{request: _request}}}} = state),
      do: state |> put_in([Access.key!(:status), :update, :requested?], true) |> request_check()

    def request(%{status: %{update: %{phase: :available, pending: info}}} = state),
      do:
        state
        |> put_in([Access.key!(:status), :update, :requested?], true)
        |> task(:stage, fn -> state.status.update.host.stage.(info) end)

    def request(state) do
      state = put_in(state.status.update.requested?, true)
      if state.status.update.phase == :staged, do: tick(state), else: check(state)
    end

    defp request_check(state) do
      host = state.status.update.host

      state =
        if host[:request_notice],
          do: Notices.say(state, :info, host.request_notice),
          else: state

      task(state, :check, Map.get(host, :request, host.check))
    end

    @doc false
    @spec check(state :: TUI.t()) :: TUI.t()
    def check(%{status: %{update: %{host: nil}}} = state), do: state

    def check(%{status: %{update: %{phase: phase, host: host}}} = state)
        when phase in [:idle, :available, :restart],
        do: task(state, :check, host.check)

    def check(state), do: state

    @doc false
    @spec result(state :: TUI.t(), result :: term()) :: TUI.t()
    def result(state, result) do
      phase = state.status.update.phase
      state = put_in(state.status.update.task, nil)
      complete(state, phase, result)
    end

    defp complete(state, :check, {:ok, %{"version" => version} = info}) when is_binary(version) do
      state =
        state
        |> put_in([Access.key!(:status), :update, :pending], info)
        |> put_in([Access.key!(:status), :update, :phase], :available)

      state =
        if news?(state, {version, :available}) do
          notice = Map.get(info, "notice", "Lemieux v#{version} is available · /update")

          state
          |> Notices.say(:info, notice)
          |> put_in([Access.key!(:status), :update, :announced], {version, :available})
        else
          state
        end

      if state.status.update.host.auto? or state.status.update.requested?,
        do: task(state, :stage, fn -> state.status.update.host.stage.(info) end),
        else: state
    end

    # A newer release the host would not trust. Nothing is staged, so there is
    # no pending offer for /update to install; the next check asks again.
    defp complete(state, :check, {:unverified, version, reason}) when is_binary(version) do
      say? = news?(state, {version, reason})

      state =
        state
        |> put_in([Access.key!(:status), :update, :announced], {version, reason})
        |> clear()

      if say?,
        do: Notices.say(state, :warning, unverified_message(state, version, reason)),
        else: state
    end

    defp complete(state, :check, {:installed, version}) when is_binary(version) do
      announce? = state.status.update.installed != version or state.status.update.requested?
      state = state |> put_in([Access.key!(:status), :update, :installed], version) |> clear()
      if announce?, do: restart_notice(state), else: state
    end

    defp complete(state, :check, :current) do
      if state.status.update.installed do
        state = if state.status.update.requested?, do: restart_notice(state), else: state
        clear(state)
      else
        if state.status.update.requested?,
          do: reset(state, :info, "lmx is up to date."),
          else: clear(state)
      end
    end

    defp complete(state, :check, {:error, reason}) do
      if state.status.update.requested?,
        do: failed(state, reason, "The update check is unavailable · /update to retry."),
        else: clear(state)
    end

    # An lmx that was unpacked by hand, or runs on Windows, installs nothing
    # itself (`Lmx.Update.host/1`). "Use the Unix installer" read as a
    # different installer on macOS, which is Unix too; install.sh is the
    # one, and it takes macOS and Linux only.
    defp complete(state, :stage, {:error, :manual_install}),
      do:
        reset(
          state,
          :info,
          "Download an update from https://github.com/houllette/lemieux/releases and restart lmx. " <>
            "On macOS and Linux, install lmx with install.sh to get automatic updates."
        )

    defp complete(state, :stage, {:ok, staged}) when is_map(staged) do
      state =
        state
        |> put_in([Access.key!(:status), :update, :pending], staged)
        |> put_in([Access.key!(:status), :update, :phase], :staged)

      tick(state)
    end

    defp complete(state, :apply, {:ok, :hot}) do
      host = state.status.update.host
      host = if Map.has_key?(host, :refresh), do: host.refresh.(), else: host
      state = put_in(state.status.update.host, host)
      state = put_in(state.status.update.installed, nil)
      reset(state, :info, "Update applied · running v#{Lemieux.version()}.")
    end

    defp complete(state, :apply, {:ok, :restart}) do
      version = get_in(state.status.update.pending, [:info, "version"])
      state = put_in(state.status.update.installed, version || "the new version")

      state =
        reset(
          state,
          :info,
          restart_message(
            state,
            "Update installed · restart lmx for it to take effect. Rebuild selected extensions for the new version."
          )
        )

      state = put_in(state.status.update.phase, :restart)
      schedule(state)
    end

    defp complete(state, :apply, {:error, {:rollback_failed, _}}),
      do:
        reset(
          state,
          :error,
          "The live update and rollback failed. Save your draft and restart lmx to restore a verified runtime."
        )

    defp complete(state, :apply, {:error, {:rolled_back, _}}),
      do:
        reset(
          state,
          :error,
          "The live update was rolled back. This build could not be activated safely; wait for a newer release or review and reinstall its verified archive explicitly."
        )

    defp complete(state, :apply, {:error, :quarantined_update}),
      do:
        reset(
          state,
          :warning,
          "This update previously failed its live activation. Wait for a newer release or review and reinstall its verified archive explicitly."
        )

    defp complete(state, :apply, {:error, :superseded_update}),
      do:
        reset(
          state,
          :warning,
          "A newer update is already installed by another session. Restart lmx to use it."
        )

    defp complete(state, _phase, {:error, reason}),
      do:
        failed(
          state,
          reason,
          "The update could not be completed · /update to retry. Your session is still open."
        )

    defp complete(state, _phase, _unexpected),
      do: reset(state, :error, "The update host returned an invalid result · /update to retry.")

    # Periodic checks repeat a verdict silently; /update always answers.
    defp news?(state, verdict),
      do: state.status.update.announced != verdict or state.status.update.requested?

    defp restart_notice(state),
      do:
        Notices.say(
          state,
          :info,
          restart_message(
            state,
            "Update v#{state.status.update.installed} installed · restart lmx for it to take effect."
          )
        )

    defp restart_message(state, default) do
      case state.status.update.host do
        %{restart_notice: notice} -> notice.(state.status.update.installed)
        _host -> default
      end
    end

    defp unverified_message(state, version, reason) do
      case state.status.update.host do
        %{unverified_notice: notice} ->
          notice.(version, reason)

        _host ->
          "Lemieux v#{version} is available, but it could not be verified, so it was not installed."
      end
    end

    defp failed(state, reason, default) do
      message =
        case state.status.update.host do
          %{error_notice: notice} -> notice.(reason) || default
          _host -> default
        end

      reset(state, :error, message)
    end

    @doc false
    @spec tick(state :: TUI.t()) :: TUI.t()
    def tick(%{status: %{update: %{phase: :staged}}} = state) do
      if idle?(state) do
        app = self()
        host = state.status.update.host
        staged = state.status.update.pending
        task(state, :apply, fn -> host.apply.(staged, app) end)
      else
        Process.send_after(self(), :update_idle, 500)
        state
      end
    end

    def tick(state), do: state

    defp idle?(state),
      do:
        not state.conversation.busy? and not state.resume.busy? and
          state.resume.startup_status != :loading and state.history.queued == [] and
          state.turn.started_at == nil

    defp task(state, phase, fun) do
      task = Task.Supervisor.async_nolink(state.status.update.host.tasks, fun)

      state =
        case phase do
          :stage ->
            Notices.say(
              state,
              :info,
              Map.get(
                state.status.update.host,
                :stage_notice,
                "Downloading the update in the background…"
              )
            )

          :apply ->
            Notices.say(
              state,
              :info,
              Map.get(state.status.update.host, :apply_notice, "Installing the update…")
            )

          :check ->
            state
        end

      state
      |> put_in([Access.key!(:status), :update, :phase], phase)
      |> put_in([Access.key!(:status), :update, :task], task)
    end

    defp reset(state, kind, notice) do
      state |> clear() |> Notices.say(kind, notice)
    end

    defp clear(state) do
      update = state.status.update

      put_in(state.status.update, %{
        update
        | phase: if(update.installed, do: :restart, else: :idle),
          task: nil,
          pending: nil,
          requested?: false
      })
    end
  end
end

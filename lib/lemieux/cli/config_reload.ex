defmodule Lemieux.CLI.ConfigReload do
  @moduledoc """
  Polls the active config path for an interactive session. Reading the path
  afresh also detects editors' atomic rename saves, without a filesystem
  watcher dependency. A single one-second poll coalesces saves. The process
  lives only as long as both the screen and session.

  Only System One settings are live. The full file is validated first; live
  fields are resolved together against the original startup settings, so a
  pending routing or credential change cannot leak into an active provider.
  Hook replacement is an atomic idle-only session call. Failed reads and
  failed provider resolution retain the previous working hooks. Existing
  extension documents keep all compaction and budget history.
  """
  use GenServer
  alias Lemieux.CLI.{Config, SystemOneCompaction}
  alias Lemieux.{Harness, Session}
  @live ~w(systemone_compaction systemone_providers)

  @doc "Starts polling a configured interactive session; hermetic sessions do nothing."
  @spec start(
          session :: pid(),
          app :: pid(),
          options :: Lemieux.CLI.Options.t(),
          opts :: keyword()
        ) :: GenServer.on_start() | :ignore
  def start(session, app, options, opts \\ []) do
    if is_binary(Config.path(options.config)) and is_pid(app) do
      runtime = Session.info(session).supervisor

      spec = %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [{session, app, options, opts}]},
        restart: :temporary
      }

      DynamicSupervisor.start_child(Lemieux.Supervisor.background_supervisor(runtime), spec)
    else
      :ignore
    end
  end

  @doc false
  @spec start_link(args :: tuple()) :: GenServer.on_start()
  def start_link({session, _app, _options, _opts} = args) do
    info = Session.info(session)

    name =
      {:via, Registry,
       {Lemieux.Supervisor.background_registry(info.supervisor), {:config_reload, info.id}}}

    GenServer.start_link(__MODULE__, args, name: name)
  end

  @doc "Rechecks a save immediately before a new prompt is dispatched."
  @spec before_prompt(session :: pid()) :: :ok
  def before_prompt(session) do
    info = Session.info(session)

    case Registry.lookup(
           Lemieux.Supervisor.background_registry(info.supervisor),
           {:config_reload, info.id}
         ) do
      [{watcher, _}] -> poll(watcher)
      [] -> :ok
    end
  end

  @doc false
  @spec poll(watcher :: pid()) :: :ok
  def poll(watcher), do: GenServer.call(watcher, :poll)

  @impl true
  def init({session, app, options, opts}) do
    Process.monitor(session)
    Process.monitor(app)

    live? =
      not Keyword.has_key?(opts, :profile) and options.extension_profile == nil and
        not options.build_ext and
        "systemone_compaction" not in Config.get(options.config, "disabled_extensions", [])

    base = Session.request_hooks(session) |> Enum.reject(&systemone_hook?/1)

    state = %{
      session: session,
      app: app,
      options: options,
      startup: options.config,
      active: options.config,
      base: base,
      live: if(live?, do: @live, else: []),
      notice: nil
    }

    Process.send_after(self(), :poll, 1_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, 1_000)
    {:noreply, refresh(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

  @impl true
  def handle_call(:poll, _from, state), do: {:reply, :ok, refresh(state)}

  defp refresh(state) do
    case Config.load(Config.path(state.startup)) do
      {:ok, config} ->
        update(state, config)

      {:error, _reason} ->
        notice(state, :warning, [
          "Config could not be reloaded. Fix the file or schema version; the last working settings remain active."
        ])
    end
  end

  defp update(state, config) do
    changed = Enum.filter(changed(state.active.settings, config.settings), &(&1 in state.live))

    pending = changed(state.startup.settings, config.settings) -- state.live

    effective = %{
      state.startup
      | settings:
          Map.merge(
            Map.drop(state.startup.settings, state.live),
            Map.take(config.settings, state.live)
          )
    }

    case apply_live(state, effective, changed) do
      {:ok, state} ->
        applied =
          if changed == [], do: [], else: ["Config reloaded: #{Enum.join(changed, ", ")}."]

        restart =
          if pending == [],
            do: [],
            else: ["Config changed. Restart lmx to apply: #{Enum.join(pending, ", ")}."]

        notice(state, if(pending == [], do: :info, else: :warning), applied ++ restart)

      {:error, :busy} ->
        notice(state, :info, [
          "Config changed. Supported changes will apply after the active turn finishes."
        ])

      {:error, _reason} ->
        notice(state, :warning, [
          "Config could not be applied. Check the System One provider settings; the last working settings remain active."
        ])
    end
  end

  defp apply_live(state, _config, []), do: {:ok, state}

  defp apply_live(state, config, _changed) do
    with {:ok, spec} <- SystemOneCompaction.spec(config, state.options.ixway),
         {:ok, hooks} <- hooks(spec),
         :ok <- Session.set_request_hooks(state.session, state.base ++ hooks) do
      {:ok, %{state | active: config}}
    end
  end

  defp hooks(nil), do: {:ok, []}

  defp hooks(spec) do
    case Harness.assemble(%Harness{}, [spec]) do
      {:ok, harness} -> {:ok, Keyword.get_values(harness.hooks || [], :prepare_next_turn)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp changed(previous, current),
    do:
      (Map.keys(previous) ++ Map.keys(current))
      |> Enum.uniq()
      |> Enum.filter(&(Map.get(previous, &1) != Map.get(current, &1)))
      |> Enum.sort()

  defp systemone_hook?(hook),
    do: :erlang.fun_info(hook, :module) == {:module, LemieuxSystemOneCompaction}

  defp notice(state, kind, texts) do
    value = {kind, texts}

    if state.notice != value,
      do: send(state.app, {:config_reload_notice, state.session, kind, texts})

    %{state | notice: value}
  end
end

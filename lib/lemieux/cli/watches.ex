defmodule Lemieux.CLI.Watches do
  @moduledoc "Automatic per-session watch hosts for lmx; library embedders own their own hosts."
  alias Lemieux.CLI.Config
  alias Lemieux.Extensions.Watches
  alias Lemieux.Extensions.Watches.Server
  alias Lemieux.Jobs.Journal.Files
  alias Lemieux.Session
  alias Lemieux.Supervisor, as: Sup

  @doc "Builds inert equipment; preparation and explain start no monitors."
  @spec spec(options :: struct(), opts :: keyword(), profile? :: boolean()) :: term()
  def spec(options, opts, profile?) do
    settings = Config.get(options.config, "watches", true)

    if settings != false do
      sources = if is_map(settings), do: Map.keys(Map.get(settings, "sources", %{})), else: []

      sources =
        case Keyword.get(opts, :watch_sources) do
          nil -> ["github", "background"] ++ sources
          selected -> Map.keys(selected)
        end

      {Watches,
       [
         manager: &resolve/1,
         sources: sources,
         auto_background: true,
         equip_tool: enabled?(options, opts, settings, profile?),
         allow_follow_up: follow_up?(settings)
       ]}
    end
  end

  defp enabled?(options, opts, settings, profile?) do
    personal? = is_binary(options.host.state_dir)
    catalog? = not Keyword.has_key?(opts, :tools) or Keyword.has_key?(opts, :watch_sources)
    personal? and catalog? and settings != false and not profile?
  end

  @doc "Keeps host-only journal and source settings outside the harness."
  @spec options(options :: struct(), opts :: keyword()) :: keyword()
  def options(options, opts) do
    settings = Config.get(options.config, "watches", true)

    [
      dir: options.host.state_dir,
      enabled:
        settings != false and
          "watches" not in Config.get(options.config, "disabled_extensions", []),
      allow_follow_up: follow_up?(settings),
      sources: if(is_map(settings), do: Map.get(settings, "sources", %{}), else: %{})
    ] ++
      Keyword.take(opts, [:watch_sources, :watch_options])
  end

  defp follow_up?(settings) when is_map(settings), do: Map.get(settings, "follow_up", true)
  defp follow_up?(_settings), do: true

  @doc "Starts the equipped session's monitor automatically and reconnects its durable queue."
  @spec start(session :: pid(), opts :: keyword()) :: :ok | {:error, term()}
  def start(session, opts) do
    if opts[:watch_host][:enabled] do
      start_host(session, opts, Keyword.fetch!(opts, :watch_host))
    else
      :ok
    end
  end

  defp start_host(session, opts, host) do
    id = Session.id(session)
    runtime = Keyword.fetch!(opts, :supervisor)
    name = {:via, Registry, {Sup.background_registry(runtime), {:watches, id}}}

    sources =
      Keyword.get(
        host,
        :watch_sources,
        Map.merge(command_sources(opts, host), %{
          "github" =>
            {Lemieux.CLI.Watches.GitHub, %{cwd: Keyword.get_lazy(opts, :cwd, &File.cwd!/0)}},
          "background" => {Watches.Background, %{session_id: id, supervisor: runtime}}
        })
      )

    authorize = fn watch ->
      watch["continuation_origin"] == "user" or host[:allow_follow_up] == true
    end

    server_opts =
      [
        name: name,
        session_id: id,
        session: session,
        sources: sources,
        journal: if(host[:dir], do: Files.new(Path.join([host[:dir], "watches", id]))),
        task_supervisor: Sup.task_supervisor(runtime),
        authorize: authorize,
        default_follow_up: host[:allow_follow_up]
      ] ++ Keyword.get(host, :watch_options, [])

    case DynamicSupervisor.start_child(Sup.background_supervisor(runtime), {Server, server_opts}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, pid}} ->
        Watches.attach(pid, session,
          authorize: authorize,
          sources: sources,
          default_follow_up: host[:allow_follow_up]
        )

      {:error, reason} ->
        {:error, {:watch_host, reason}}
    end
  end

  defp command_sources(opts, host) do
    environment =
      Keyword.get(opts, :environment) || opts[:harness].environment || Lemieux.Environment.local()

    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)

    Map.new(host[:sources], fn {name, command} ->
      {name,
       {Lemieux.CLI.Watches.Command, %{command: command, environment: environment, cwd: cwd}}}
    end)
  end

  @doc "Resolves only the manager for this runtime and session."
  @spec resolve(context :: map()) :: {:ok, pid()} | {:error, :watches_unavailable}
  def resolve(%{supervisor: runtime, session_id: id}) do
    case Registry.lookup(Sup.background_registry(runtime), {:watches, id}) do
      # Registry removal follows its owner's DOWN asynchronously. A closed
      # volatile session must not expose that dead owner as an available host.
      [{pid, _value}] ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :watches_unavailable}

      [] ->
        {:error, :watches_unavailable}
    end
  end
end

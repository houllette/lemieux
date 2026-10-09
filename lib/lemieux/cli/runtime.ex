defmodule Lemieux.CLI.Runtime do
  @moduledoc """
  Mounting a runtime and starting a session, the way `lmx` does it.

  Every command that needs an agent needs the same four things: a supervision
  tree, a store, a provider and a session subscribed to the current process.
  This is that recipe, in one place, so `run` and the TUI cannot
  drift into configuring the library differently — and so the injection seam
  the tests use is one seam rather than one per command.

  `lmx` mounts `Lemieux.Supervisor` itself, like any other host. Nothing here
  is a privileged path into the library: an embedder's setup is this file,
  minus the option parsing.

  ## What a session is made of

  A session starts from a `Lemieux.Harness`: a base built from the parsed
  options and the host's `opts`, with the mode's extensions applied over it
  by `Lemieux.Harness.assemble/2`. `extensions/3` is the one list that says
  what `lmx` adds and in what order, so two commands cannot equip a session
  differently by each keeping their own. What each mode applies:

    * `lmx run` — `Lemieux.Extensions.Hooks` for `--hooks` and for the
      config file's `"hooks"`, `Lemieux.Extensions.Permissions` when a
      permission mode is configured (off by default),
      `Lemieux.Extensions.MCP` for `--mcp-config`, the config file's
      `"mcp_servers"` and the repository's own file — the last only once a
      person has trusted it (`Lemieux.MCP.Trust`) or `--project-mcp` says so —
      with `Lemieux.Extensions.MCPDiscovery` in `:auto` mode beside them,
      `Lemieux.Extensions.Web` for configured Brave research or explicit web
      flags, `Lemieux.Extensions.Elixir` for `--elixir`, the coding recipe's
      `environment_context`, `planning` (the `todo` tool), `continuation`
      (unfinished plans and cut-off answers are sent back), `verify` and
      `budget` (what is left of `--max-requests`),
      `Lemieux.Extensions.Delegation` unless `--no-delegate`, then
      `Lemieux.Extensions.Search` (`grep`, `glob`),
      `Lemieux.Extensions.ApplyPatch` (for GPT-5-family models) and, last
      among the catalog shapers, `Lemieux.Extensions.Checkpoints`, which
      records what the file tools change so the terminal UI can undo it —
      `verify` is given the same directory, so the check it runs after
      edits is recorded with them;
    * the TUI — the same as `lmx run`, plus `Lemieux.Extensions.Interactive`
      and, in an Elixir project, `Lemieux.Extensions.Elixir` without its
      profile so `/elixir` is there to switch to it.

  Both apply `Lemieux.Extensions.Workspace` over the workspace their command
  discovered, when it discovered one (see "Workspace discovery" below).

  `disabled_extensions` in the config file withholds any of these by the
  name given in `Lemieux.CLI.Config`. Every one of them is also what
  `lmx explain` reports under `"applied"`.

  ## The environment commands run in

  `lmx` builds the session's `Lemieux.Environment` itself:
  `Lemieux.Environment.Local` withholding credential-shaped variables (any
  name containing `KEY`, `TOKEN`, `SECRET`, `PASSWORD` or `PASSWD` — a name
  heuristic, see `Lemieux.Environment.Credentials`) from commands, hooks, the
  eval node and MCP stdio servers, less the config file's
  `"credential_allowlist"`; or, when `"sandbox"` or `--sandbox` asks for it,
  `Lemieux.Environment.Sandbox` around that, hiding — beside its own list
  and the config file's `"hidden"` — the config file, state, transcript and
  MCP token locations this run resolved (`Lemieux.CLI.Runtime.SecretPaths`).
  `"scrub_credentials": false` turns the scrubbing off. An embedding host
  that passes `:environment` gets exactly the environment it passed.
    * `--extension-profile` in any mode — `Lemieux.Extension.Profile`,
      placed before the catalog extensions so `ask_user` and the scout join
      the profile's tools rather than being replaced by them;
    * `--extension NAME`, `--extension-dir PATH` and the config file's
      `"extensions"` in any mode — the person's own code, loaded from disk by
      `Lemieux.CLI.Extensions` and applied after everything shipped, in the
      order given, with what was loaded recorded under
      `harness_context["extensions"]["loaded"]` beside `"applied"`.

  The order is the one the hosts applied by hand before there was a list:
  the interactive tool, then the network tools, then the Elixir profile that
  narrows the catalog, then the workspace layer over the result, then the
  scout beside it, then whatever the person loaded. A host embedding the CLI
  appends its own with `extensions:`, after all of these, where it can wrap
  what `lmx` did and what the person added.

  ## Workspace discovery

  `prepare/2` discovers no workspace of its own: the command does, before it
  calls it, and passes the result as `workspace:`. The TUI discovers once
  per screen (`discover_workspace/2`) and hands that to every session it
  starts. `lmx run` and `lmx explain` go through `with_workspace/2`, which
  discovers one for a new session, and for a resumed one whose transcript
  recorded a workspace layer, unless `--bare`, `--system`, `--build-ext` or
  `--extension-profile` leaves the workspace out. An embedding host that
  passes no `workspace:` gets exactly the prompt and tools it supplied.

  ## Personal state

  Checkpoints, trusted MCP decisions and remembered permission rules live
  under the options' `state_dir` (`~/.lmx`). With none — `--config none` —
  checkpoints are off, repository MCP servers start only with
  `--project-mcp`, and permission rules are not remembered; see
  `Lemieux.CLI.Options`.

  ## What is not in the harness

  Provider, store, model, supervisor, subscriber and working directory stay
  outside it and are passed to `Lemieux.start_session/1` beside it. They are
  this host's authority — `Lemieux.Harness` says why no extension may reach
  them — and `prepare/2` resolves them once so `start/2` has nothing left to
  decide.

  ## Model routes

  The provider `lmx` builds is the direct `req_llm` connection, with every
  registered model route beside it (`Lemieux.CLI.Routes`): Ixway when it is
  configured, and the routes the loaded extensions offer
  (`Lemieux.Extension.Routes`). A model's name chooses among them —
  `ixway:team/coding`, `relay:qwen3-32b`, `anthropic:claude-sonnet-5` — and a
  request never crosses from one to another (`Lemieux.CLI.ProviderMux`).
  `--router ixway` and `--router NAME` make that route the sole connection
  for `lmx run`, as `--ixway` always has; the terminal UI keeps the direct
  providers beside it to switch to. The hosts register the routes before
  their own checks (`with_routes/2`), so a model on a route is never refused
  as a provider `req_llm` does not know, and `prepare/2` readies the start
  model's route and resolves `NAME:@default` on it
  (`Lemieux.Providers.ReqLLM.prepare/2`) for a new session and for a resume
  alike. A host that passes `:provider` has decided where requests go, and
  no route is registered for it.

  Explicit host session constraints (including hooks, environment, tool
  profile and budgets) are reapplied after assembly. Prompts, catalogs, host
  tools, MCP servers and harness context are composition inputs instead.
  `start/2` overrides are the final authority for every field. This is the
  same precedence as explicit options beside `harness:` in the library.

  On resume an internal, versioned reconstruction record supplies the
  original prompt and module catalog to the currently selected extensions.
  It contains no executable callbacks or private initialization options.
  Missing tool-transforming extensions stop preparation unless the host
  explicitly supplies a replacement `:tools` catalog. Extensions are never
  loaded because a transcript names them.
  """

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Extensions, as: LoadedExtensions
  alias Lemieux.CLI.Limits
  alias Lemieux.CLI.OAuth
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.ProviderMux
  alias Lemieux.CLI.Routes
  alias Lemieux.CLI.Runtime.Assembly
  alias Lemieux.CLI.Runtime.SecretPaths
  alias Lemieux.CLI.Skills
  alias Lemieux.CLI.Startup
  alias Lemieux.CLI.SystemOneCompaction
  alias Lemieux.Conversation.Command.Builtin
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Extensions.ApplyPatch
  alias Lemieux.Extensions.Checkpoints
  alias Lemieux.Extensions.Hooks, as: HooksExtension
  alias Lemieux.Extensions.MCP, as: MCPExtension
  alias Lemieux.Extensions.MCPDiscovery
  alias Lemieux.Extensions.Permissions
  alias Lemieux.Extensions.Search
  alias Lemieux.Extensions.Web
  alias Lemieux.Extensions.Web.Brave
  alias Lemieux.Extensions.Workspace
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Harness
  alias Lemieux.ID.Shorthand
  alias Lemieux.MCP.Auth
  alias Lemieux.MCP.Auth.Store.File, as: FileStore
  alias Lemieux.MCP.Config, as: MCPConfig
  alias Lemieux.MCP.Trust
  alias Lemieux.ModelCatalog
  alias Lemieux.ModelSpec
  alias Lemieux.Prompt
  alias Lemieux.Provider
  alias Lemieux.Providers.ReqLLM, as: ReqLLMProvider
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools

  # The screen's fields a host may pass beside the session's; the full list
  # of base fields is `base_fields/0`.
  @host_fields [
    :theme,
    :themes,
    :keys,
    :layout,
    :status_line,
    :followups,
    :processing,
    :startup_animation,
    :notices,
    :renderers,
    :commands
  ]
  # Where composition begins: the workspace layer and everything after it run
  # over the catalog the equipment produced, which is what a resume's
  # assembly record keeps (`Lemieux.CLI.Runtime.Assembly`). `:checkpoints`
  # is here as well as `:workspace` so that a session with no workspace
  # (`lmx run`) still records the catalog before the wrappers: a wrapped tool
  # is not a name a transcript can restore, and wrapping on every resume is
  # how the wrappers come back.
  @composition [:workspace, :loaded, :checkpoints, :host]

  # The tools lmx adds to a new catalog. Equipment, applied only when a
  # catalog is being equipped: a resume keeps the catalog its transcript
  # recorded, which already has them if the session did — the rule that
  # stops a session deliberately started with fewer tools from getting them
  # back by being resumed (`Lemieux.ConfigurationTest`).
  @equipment_anchors [
    :hooks,
    :config_hooks,
    :permissions,
    :mcp,
    :mcp_discovery,
    :profile,
    :interactive,
    :web,
    :elixir
  ]

  # Long enough for a command hook at its default 60s timeout plus whatever
  # an Elixir observer does with the transcript; a stop that outlives it
  # leaves the session to the halt rather than hanging the exit.
  @stop_timeout :timer.minutes(2)

  @typedoc """
  A session ready to start: the assembled harness, the host authority that
  goes beside it, and the transcript it continues. `start/2` starts it; a
  host reads `:harness` first — the TUI for its screen, the one-shot host for
  what to print before the answer.
  """
  @type prepared :: %{
          harness: Harness.t(),
          options: keyword(),
          resume: String.t() | nil,
          model: String.t(),
          routes: [String.t()],
          permissions: Permissions.Handle.t() | nil,
          sandbox: map() | nil,
          checkpoints: Path.t() | nil,
          mcp_trust: map() | nil
        }

  @doc """
  The ordinary catalog a new session in this mode gets: the host's tools or
  the defaults, with the profile, `ask_user`, the network tools and the
  workspace's overlay applied, and without the Elixir profile or the scout.

  What `/elixir` toggles back to. The two exclusions are the point: the
  Elixir profile is the mode being toggled, and the `delegate` tool is a
  struct the session keeps that the host re-reads from it at toggle time.
  """
  @spec standard_tools(options :: Options.t(), opts :: keyword()) ::
          {:ok, [Lemieux.Tool.t()]} | {:error, String.t()}
  def standard_tools(%Options{} = options, opts) when is_list(opts) do
    context = %{
      new?: true,
      recorded: %{},
      interactive?: interactive?(opts),
      provider: nil,
      model: options.model,
      cwd: Keyword.get_lazy(opts, :cwd, &File.cwd!/0),
      permissions: nil,
      credentials: credential_policy(options, opts)
    }

    # What `/elixir` off returns to is everything that equips the catalog
    # except the two the toggle itself owns: the Elixir profile, and delegation,
    # which the screen carries across the toggle by hand. A person's loaded
    # extension and a host's own belong in it as much as web search does; a
    # catalog that forgot them would lose their tools on the first toggle.
    with {:ok, loaded} <- loaded(options, opts),
         {:ok, extensions} <-
           extensions(%{options | elixir: false, delegate: false}, opts, context, loaded),
         catalog =
           Keyword.take(extensions, [
             :profile,
             :interactive,
             :web,
             :mcp_discovery,
             :search,
             :apply_patch,
             :planning,
             :a2ui,
             :workspace,
             :loaded,
             :checkpoints,
             :host
           ]),
         base = Harness.new(tools: Keyword.get(opts, :tools)),
         {:ok, harness} <- assemble(base, Keyword.values(catalog), opts) do
      {:ok, harness.tools || Tools.default()}
    end
  end

  @doc """
  Starts the supervision tree, linked to the calling process.

  Linked because this command owns the runtime lifetime. A runtime that
  outlived the command that started it would keep a standalone VM alive after
  the work was done, while an embedder normally supplies its own supervisor.
  """
  @spec mount(opts :: keyword()) :: {:ok, atom()}
  def mount(opts) do
    name = Keyword.get(opts, :supervisor, Lemieux.Supervisor)

    case Lemieux.Supervisor.start_link(name: name) do
      {:ok, _pid} -> {:ok, name}
      {:error, {:already_started, _pid}} -> {:ok, name}
    end
  end

  @doc """
  Starts a session subscribed to the calling process.

  `prepare/2` followed by `start/2`. Options not supplied are filled in from
  the command line and then from the environment: see `Lemieux.CLI.Options`.
  """
  @spec start_session(options :: Options.t(), opts :: keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_session(%Options{} = options, opts) do
    with {:ok, prepared} <- prepare(options, opts), do: start(prepared)
  end

  @doc """
  Everything short of starting: the harness assembled, the host authority
  resolved, nothing mounted.

  Split from `start/2` because two hosts need the harness before the
  session exists. The TUI reads its host fields — skills, notices, the
  status line — to open the screen the first session will be drawn on, and
  the one-shot host prints `harness.notices` before its answer. Doing this
  without mounting also means a refused option leaves no supervisor running
  behind it.

  ## Options

  Beside the seams (`:provider`, `:store`, `:subscriber`, `:supervisor`,
  `:cwd`) and any `Lemieux.Harness` field, this reads:

    * `:tools` — an explicit catalog, replacing the defaults or, on a resume,
      the recorded one;
    * `:interactive?` — somebody is attached to answer, so
      `Lemieux.Extensions.Interactive` applies;
    * `:workspace` — a `Lemieux.Extensions.Workspace.Discovery` the host
      discovered, so `Lemieux.Extensions.Workspace` applies;
    * `:profile` — a `{Lemieux.Extension.Profile, opts}` from
      `Lemieux.CLI.ExtensionExperience`;
    * `:extensions_dir` — where `--extension NAME` and the config file's
      `"extensions"` resolve a name, instead of
      `Lemieux.CLI.Extensions.default_root/0`; for tests and hosts with a
      root of their own;
    * `:extensions` — the host's own, applied after `lmx`'s and after
      anything the person loaded;
    * `:startup_step` — an optional host callback `(id, text, status)` for
      extension loading and initialization. IDs are bounded strings and
      statuses are `"busy"`, `"ok"` or `"fail"`; it is never stored in the harness;
    * `:routes` — the model routes `with_routes/2` registered, so they are
      not registered a second time here; without it, and without
      `:provider`, they are registered now;
    * `:subagent_options` — overrides for the scout's `Lemieux.Subagent.Delegate`;
    * `:permissions` — a `Lemieux.Extensions.Permissions` handle the host
      created with `permissions/2`, so a screen that switches mode switches
      it for every session it starts; without one, a configured mode gets a
      handle of its own here;
    * `:state_dir` — where personal state lives, instead of the options';
      tests pass a temporary directory.

  The returned map carries, beside the harness, what a screen needs to show
  and change about the session it starts: the permission handle, the
  sandbox's description, the checkpoint directory `/undo` reads, and the
  repository MCP servers still waiting for a trust decision.
  """
  @spec prepare(options :: Options.t(), opts :: keyword()) ::
          {:ok, prepared()} | {:error, term()}
  def prepare(%Options{} = options, opts) when is_list(opts) do
    store = store(options, opts)

    options =
      put_in(options.host.state_dir, Keyword.get(opts, :state_dir, options.host.state_dir))

    with :ok <- experience_boundary(options, opts),
         {:ok, resume} <- resolved_resume(store, options.resume),
         {:ok, permissions} <- permissions(options, opts),
         {:ok, environment} <- environment(options, opts, store),
         recorded = recorded_config(store, resume),
         # Current host ceilings override history; omitted ceilings retain it.
         # Reapplying these after extensions prevents a profile relaxing a CLI cap.
         opts = Keyword.merge(Limits.restore(Options.limits(options), recorded), opts),
         {:ok, loaded} <- loaded(options, opts),
         {:ok, routes} <- routes(options, opts, loaded),
         provider = Keyword.get_lazy(opts, :provider, fn -> provider(options, routes) end),
         :ok <- reachable(opts, provider, requested_model(options, recorded)),
         {:ok, provider, model} <-
           prepare_provider(provider, requested_model(options, recorded)),
         opts = configured_effort(opts, options.config, model, resume),
         context = %{
           new?: is_nil(resume),
           recorded: recorded,
           provider: provider,
           model: model,
           interactive?: interactive?(opts),
           cwd: Keyword.get_lazy(opts, :cwd, &File.cwd!/0),
           permissions: permissions,
           credentials: credential_policy(options, opts)
         },
         {:ok, extensions} <- extensions(options, opts, context, loaded),
         {:ok, tools} <- assembly_tools(opts, recorded, resume, Keyword.values(extensions)),
         {equipment, composition} <-
           Enum.split_while(extensions, fn {tag, _} -> tag not in @composition end),
         base_opts =
           opts |> Keyword.put(:tools, tools) |> Keyword.put_new(:environment, environment),
         {:ok, equipped} <-
           assemble(
             base(options, base_opts, recorded, resume, loaded),
             Keyword.values(equipment),
             opts
           ),
         {:ok, harness} <-
           Assembly.apply(equipped, Keyword.values(composition), opts) do
      harness = struct!(harness, host_constraints(opts))
      harness = %{harness | disabled_tools: harness.disabled_tools || recorded["disabled_tools"]}
      # Keep ceilings in the recorded assembly and `lmx explain`. A notice is
      # rendered as a warning on every TUI start, even when nothing is wrong.
      harness = Limits.remember(harness)
      harness = %{harness | notices: harness.notices ++ notices(options, opts, context)}

      {:ok,
       %{
         harness: harness,
         model: model,
         resume: resume,
         routes: Routes.names(routes),
         permissions: permissions,
         sandbox: Sandbox.describe(harness.environment),
         checkpoints: checkpoints_dir(options, disabled(options)),
         mcp_trust: mcp_trust(options, context),
         options:
           options
           |> authority(opts, store, provider, model, recorded, resume)
           |> Keyword.put_new(:mcp_connect_opts, mcp_connect_opts(options, context))
           |> maybe_put_new(:input_modalities, Config.input_modalities(options.config))
       }}
    end
  end

  defp assembly_tools(opts, _recorded, nil, _extensions), do: {:ok, Keyword.get(opts, :tools)}

  defp assembly_tools(opts, recorded, _resume, extensions) do
    case Keyword.fetch(opts, :tools) do
      {:ok, tools} -> {:ok, tools}
      :error -> Assembly.seed(recorded, extensions)
    end
  end

  @doc """
  Mounts the runtime and starts the prepared session.

  `overrides` are host authority decided at the last moment — the TUI
  passes `subscriber:` from inside the app process, because the process
  drawing must be the one subscribed — and win over what `prepare/2`
  resolved. `--resume` is decided here rather than in each command, so
  `lmx run --resume` and `lmx --resume` cannot disagree about what resuming
  means.
  """
  @spec start(prepared :: prepared(), overrides :: keyword()) :: {:ok, pid()} | {:error, term()}
  def start(%{harness: harness, options: options, resume: resume}, overrides \\ [])
      when is_list(overrides) do
    with {:ok, _supervisor} <- mount(options) do
      session_opts = [{:harness, harness} | Keyword.merge(options, overrides)]

      case resume do
        nil -> Lemieux.start_session(session_opts)
        id -> Lemieux.resume_session([{:resume, id} | session_opts])
      end
    end
  end

  # Only what was typed on this command line asks for a workspace. Selections
  # saved in the config file (`lmx plugin install`) are standing choices, not
  # a request this command made: counting them broke `lmx explain`, `--bare`,
  # `--system` and every resume for anyone who had installed a plugin, with
  # an error about flags they never passed.
  @workspace_flags [:skill_dir, :plugin_dir, :marketplace, :plugin]

  defp experience_boundary(%Options{given: given}, opts) do
    requested? = Enum.any?(@workspace_flags, &Keyword.has_key?(given, &1))

    if requested? and not match?(%Discovery{}, Keyword.get(opts, :workspace)) do
      {:error,
       "skill and plugin flags belong to the full TUI workspace experience; " <>
         "use lmx/lmx tui, or pass a host-discovered :workspace"}
    else
      :ok
    end
  end

  @doc """
  `opts` with the workspace a one-shot command composes over, the way
  `lmx run` and `lmx explain` decide it.

  A workspace the host already discovered is used as it is. A run that left
  the workspace out — `--bare`, `--system`, `--build-ext` or
  `--extension-profile` — gets none, and when the person has saved plugins
  that this leaves out, a notice naming them: a saved plugin's hooks may be
  the guards somebody relies on, and they should not stop applying without
  a word. A new session discovers the current workspace
  (`discover_workspace/2`). So does a resumed one whose transcript recorded
  a workspace layer, as the terminal UI does: today's files replace that
  layer rather than stacking on it, and the plugins it was started with —
  saved ones included — load again; a resume used to skip discovery and
  then refuse to start for anyone with a saved plugin. A resumed session
  that started without a layer keeps the prompt it recorded: a resume takes
  its configuration from the transcript, not from the command. Personal files
  are read only where there is a personal state directory, so
  `--config none` stays hermetic.
  """
  @spec with_workspace(options :: Options.t(), opts :: keyword()) ::
          {:ok, keyword()} | {:error, String.t()}
  def with_workspace(%Options{} = options, opts) when is_list(opts) do
    cond do
      match?(%Discovery{}, Keyword.get(opts, :workspace)) ->
        {:ok, opts}

      reason = bare_reason(options) ->
        {:ok, notice_skipped_plugins(opts, options, reason)}

      not discovers?(options, opts) ->
        {:ok, opts}

      true ->
        personal? = Keyword.get(opts, :personal?, is_binary(options.host.state_dir))

        with {:ok, discovered} <-
               discover_workspace(options, Keyword.put(opts, :personal?, personal?)) do
          {:ok, Keyword.put(opts, :workspace, discovered)}
        end
    end
  end

  defp discovers?(%Options{resume: nil}, _opts), do: true

  # An id that does not resolve is `prepare/2`'s to report, in its words.
  defp discovers?(%Options{resume: reference} = options, opts) do
    store = store(options, opts)

    case resolved_resume(store, reference) do
      {:ok, id} -> store |> recorded_config(id) |> Map.get("system") |> Discovery.composed?()
      _unresolved -> false
    end
  end

  # A portable extension profile (`--extension-profile`, `--build-ext`) is an
  # explicit configuration that must reach `lmx run`, the TUI and
  # `Lemieux.Agent` identically, so it runs bare; so does a caller who wrote
  # the whole system prompt.
  defp bare_reason(%Options{given: given} = options) do
    cond do
      given[:bare] == true -> "--bare"
      is_binary(given[:system]) -> "--system"
      options.build_ext -> "--build-ext"
      is_binary(options.extension_profile) -> "--extension-profile"
      true -> nil
    end
  end

  defp notice_skipped_plugins(opts, options, reason) do
    case Enum.map(options.plugin_dirs, &Path.basename/1) ++ options.plugins do
      [] ->
        opts

      skipped ->
        notice =
          "saved plugins are not loaded in a #{reason} run, so their hooks and MCP servers " <>
            "are off for it: #{Enum.join(skipped, ", ")}"

        Keyword.update(opts, :notices, [notice], &(&1 ++ [notice]))
    end
  end

  # An extension that could not initialise names itself. The reasons the
  # shipped ones give are already sentences naming the file, and the hosts
  # print a start error as it is, so those pass through bare; anything else
  # keeps the module for whoever reads it.
  defp assemble(base, extensions, opts) do
    result =
      Enum.reduce_while(extensions, {:ok, base}, fn extension, {:ok, current} ->
        case Startup.assemble_extension(current, extension, opts) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, harness} -> {:ok, harness}
      {:error, {_module, reason}} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # What only this host may say about a session, resolved once. `:subscriber`
  # defaults to the preparing process; a host that starts elsewhere overrides
  # it in `start/2`.
  defp authority(options, opts, store, provider, model, recorded, resume) do
    [
      supervisor: Keyword.get(opts, :supervisor, Lemieux.Supervisor),
      provider: provider,
      store: store,
      subscriber: Keyword.get(opts, :subscriber, self())
    ]
    |> Keyword.merge(Keyword.take(opts, [:cwd]))
    |> Keyword.merge(host_constraints(opts))
    |> maybe_put(:model, session_model(options, model, recorded, resume))
  end

  # Catalogs, prompts and host tools are inputs to composition. All other
  # explicit session settings are the host's final say, just as they are at
  # Lemieux.start_session/1. In particular a dependency cannot accidentally
  # erase approval hooks, replace a sandbox or relax a request ceiling.
  defp host_constraints(opts) do
    Keyword.take(
      opts,
      Harness.session_fields() -- [:system, :tools, :host_tools, :mcp_servers, :harness_context]
    )
  end

  # A new session needs a model and the CLI always has one; a resumed session
  # already has the one it was running as, so passing the default would switch
  # it on every resume. The exception is a transcript with no configuration
  # recorded — written before lemieux recorded any, or by a host that does not —
  # where there is nothing to be faithful to.
  defp session_model(_options, model, _recorded, nil), do: model

  defp session_model(%Options{given: given}, model, recorded, _resume) do
    if given[:model] || not Map.has_key?(recorded, "model"), do: model
  end

  defp requested_model(%Options{resume: nil} = options, _recorded), do: options.model

  defp requested_model(%Options{given: given} = options, recorded),
    do: given[:model] || recorded["model"] || options.model

  defp configured_effort(opts, _config, _model, resume) when not is_nil(resume), do: opts

  defp configured_effort(opts, config, model, nil) do
    case Config.effort(config, model) do
      nil -> opts
      effort -> Keyword.put_new(opts, :reasoning_effort, effort)
    end
  end

  # A model whose provider is neither one req_llm knows nor a registered
  # route cannot be served by the connection lmx built. A new session is
  # told so before this, by the hosts' own model check; a resumed transcript
  # whose route's extension is no longer selected is told here, before a
  # session exists and with what brings the route back — it used to start,
  # append the prompt and fail the first request as a provider unknown.
  # Only the direct connection is asked, and only its own "unknown provider"
  # is refused: a route's model goes to the route's preparation next, a
  # missing key and a blocked provider keep the path they had, and a host's
  # own provider serves whatever names it serves.
  defp reachable(opts, provider, model) do
    connection = connection(provider, model)

    if Keyword.has_key?(opts, :provider) or ReqLLMProvider.route(connection) != nil do
      :ok
    else
      case Provider.validate_model(connection, model, []) do
        {:error, {:unknown_model, _spec, :unknown_provider}} -> {:error, unreachable(model)}
        _served_or_refused_on_its_own_path -> :ok
      end
    end
  end

  defp connection({ProviderMux, _state} = provider, model), do: ProviderMux.child(provider, model)
  defp connection(provider, _model), do: provider

  defp unreachable(model) do
    provider = ModelSpec.provider(model)

    "#{model} names #{provider}, which is not a provider lmx knows and not a model route a " <>
      "loaded extension registers: if an extension registers #{provider}, select it " <>
      "(--extension NAME, --extension-dir PATH or the config file's \"extensions\"); " <>
      "otherwise choose another model with --model"
  end

  # The start model's route is readied and the model resolved on it, for a
  # mux and for a sole routed connection alike; a direct connection and a
  # host's own provider pass through with the model unchanged.
  defp prepare_provider({ProviderMux, _state} = provider, model),
    do: provider |> ProviderMux.prepare(model) |> named_key()

  defp prepare_provider(provider, model),
    do: provider |> ReqLLMProvider.prepare(model) |> named_key()

  # The library names the variable it reads the gateway key from. This host
  # also reads it from its config file, and the person most likely to meet
  # this error left an empty placeholder there (issue #3), so the sentence
  # says where the key goes in both.
  @ixway_key_needed "Ixway requires a gateway model key: set IXWAY_API_KEY, or save it as " <>
                      "ixway.api_key in the lmx config file."

  defp named_key({:error, %Lemieux.Ixway.Error{reason: :api_key_required}}),
    do: {:error, @ixway_key_needed}

  # `Lemieux.Provider.Route.default_model/2`'s refusals, as sentences: the
  # route is the person's choice, so the way forward is one of its models.
  defp named_key({:error, {:no_default_model, name}}),
    do:
      {:error,
       "#{name}:@default asks for the #{name} route's default model, and it advertises " <>
         "none: choose one of its models with --model #{name}:ID"}

  defp named_key({:error, {:default_model_outside_route, name, model}}),
    do:
      {:error,
       "the #{name} route advertised #{model} as its default, which is not one of its own " <>
         "models; a route's default must be #{name}:ID"}

  defp named_key(result), do: result

  @doc """
  `opts` with the model routes this invocation registers, under `:routes`,
  the way the hosts call it before their own checks.

  Loads the selected extensions and registers the routes they offer beside
  the shipped ones (`Lemieux.CLI.Routes.register/2`), and checks that a
  `--router NAME` names one of them. `opts` that already carry `:routes`, or
  a host's own `:provider`, are returned as they are: the host has decided
  where requests go. A refusal is a sentence about the command as given.
  """
  @spec with_routes(options :: Options.t(), opts :: keyword()) ::
          {:ok, keyword()} | {:error, String.t()}
  def with_routes(%Options{} = options, opts) when is_list(opts) do
    if Keyword.has_key?(opts, :provider) or Keyword.has_key?(opts, :routes) do
      {:ok, opts}
    else
      with {:ok, loaded} <- loaded(options, opts),
           {:ok, routes} <- routes(options, opts, loaded) do
        {:ok, opts |> Keyword.put(:routes, routes) |> Keyword.put(:loaded_extensions, loaded)}
      end
    end
  end

  @doc "Whether `model` names a route registered in `opts` by `with_routes/2`."
  @spec route?(opts :: keyword(), model :: String.t() | nil) :: boolean()
  def route?(opts, model) when is_list(opts),
    do: Routes.registered?(Keyword.get(opts, :routes, []), ModelSpec.provider(model))

  # The registry `with_routes/2` built, else built here. A host that supplies
  # `:provider` decides where requests go, so no route is registered for it:
  # a route's missing credential must not stop a host that never sends to it.
  defp routes(options, opts, loaded) do
    cond do
      Keyword.has_key?(opts, :routes) ->
        {:ok, Keyword.fetch!(opts, :routes)}

      Keyword.has_key?(opts, :provider) ->
        {:ok, []}

      true ->
        with {:ok, routes} <- Routes.register(options, loaded),
             :ok <- Routes.selected(options, routes),
             do: {:ok, routes}
    end
  end

  defp interactive?(opts), do: Keyword.get(opts, :interactive?, false)

  # The person's own extensions, loaded before assembly so a directory that
  # will not load stops the start here, in a sentence, rather than as a
  # session missing what was asked for. Nothing selected reads nothing.
  defp loaded(%Options{extensions: []}, _opts), do: {:ok, []}

  defp loaded(%Options{extensions: selections} = options, opts) do
    case Keyword.fetch(opts, :loaded_extensions) do
      {:ok, loaded} ->
        {:ok, loaded}

      :error ->
        LoadedExtensions.load_all(selections,
          root: Keyword.get_lazy(opts, :extensions_dir, &LoadedExtensions.default_root/0),
          # Rebuilding a bundle must not reset the person's configured options.
          options: Config.get(options.config, "extension_options", %{}),
          startup_step: opts[:startup_step]
        )
    end
  end

  # The base is the parsed options and the host's own harness fields. On a
  # resume it also carries the recorded prompt and catalog, so the extensions
  # compose over what the transcript says rather than over the defaults; a
  # value passed back unchanged writes nothing new. `Lemieux.Harness` says why
  # the struct cannot do this for itself.
  defp base(options, opts, recorded, resume, loaded) do
    opts
    |> Keyword.take(base_fields())
    # Tuning rather than configuration. It exists for models `req_llm`'s
    # database has never heard of — anything served locally — where nothing
    # else can say how big the window is, and without it those sessions never
    # compact on a threshold.
    |> Keyword.put_new(:context_window, options.context_window)
    |> Keyword.put_new(:auto_compaction, Config.get(options.config, "auto_compaction", true))
    # The session enables all automatic compaction by default. A saved false
    # also clears the threshold so the TUI cannot warn about a disabled trigger.
    |> Keyword.put_new(
      :compact_at,
      if(Config.get(options.config, "auto_compaction", true), do: :default, else: nil)
    )
    |> Keyword.put_new(:compaction_price_tiers, price_tiers(options.config))
    |> Keyword.put_new(:keep_recent_tokens, Config.get(options.config, "keep_recent_tokens"))
    |> Keyword.put_new(:summary_model, Config.get(options.config, "summary_model"))
    # A seam rather than configuration: how this host authorizes, not part of
    # what the session is, and a resumed session must not inherit somebody
    # else's credential store from a transcript.
    |> Keyword.put_new_lazy(:mcp_auth, fn -> auth(options) end)
    # The palette a sitting starts with, the palettes it can switch to, the
    # key map and what the status line calls a running turn: data in the
    # config file. The status line *itself* and the layout are modules and
    # therefore an embedding host's option rather than a name in JSON —
    # `Lemieux.Extension.Profile` records why this file never resolves a
    # module name to code.
    |> Keyword.put_new(:theme, Config.get(options.config, "theme"))
    |> Keyword.put_new(:themes, Config.get(options.config, "themes", %{}))
    |> Keyword.put_new(:keys, Config.get(options.config, "keys"))
    |> Keyword.put_new(:processing, Config.get(options.config, "processing"))
    |> Keyword.put_new(:startup_animation, Config.get(options.config, "startup_animation"))
    |> Keyword.put_new(:system, system(options, recorded, resume))
    |> Keyword.put(:tools, tools(opts, recorded, resume))
    |> Harness.new()
    |> with_loaded(loaded)
  end

  defp price_tiers(config) do
    case Config.get(config, "compaction_price_tiers") do
      nil ->
        nil

      prices ->
        Map.new(prices, fn {model, bands} ->
          {model, Enum.map(bands, &price_band/1)}
        end)
    end
  end

  defp price_band(band) do
    base = %{
      up_to: band["up_to"],
      input_per_million: band["input_per_million"],
      output_per_million: band["output_per_million"]
    }

    case band do
      %{"cached_input_per_million" => rate} -> Map.put(base, :cached_input_per_million, rate)
      _other -> base
    end
  end

  # What was loaded goes in the context before assembly, beside where
  # `Lemieux.Harness.session_options/1` will put `"applied"`: the transcript
  # then says not only which module shaped the session but which build of it,
  # from which directory. An empty list writes nothing, so a session with no
  # extensions of its own has the context it always had.
  defp with_loaded(harness, []), do: harness

  defp with_loaded(harness, loaded) do
    Harness.update_harness_context(harness, fn context ->
      extensions = Map.get(context, "extensions", %{})
      provenance = Enum.map(loaded, & &1.provenance)
      Map.put(context, "extensions", Map.put(extensions, "loaded", provenance))
    end)
  end

  # Host `opts` that are harness fields go on the base as they are: a host
  # passing `max_cost_usd:` or `status_line:` is setting that field. Everything
  # else a host may pass — the seams (`:provider`, `:store`, `:subscriber`,
  # `:cwd`) and this module's own options — is read where it is used. A
  # function rather than an attribute so the list is read at runtime: an
  # attribute would make this module recompile whenever the harness changes.
  defp base_fields, do: Harness.session_fields() ++ @host_fields

  # A new session's base prompt is what was typed or configured, else the
  # default — always a string, because the workspace layer composes over it.
  defp system(%Options{resume: nil} = options, _recorded, nil),
    do: options.system || Prompt.default()

  # A resume keeps the prompt its transcript recorded unless `--system` was
  # typed: `options.system` also holds the config file's prompt, and applying
  # that would rewrite every resumed conversation.
  defp system(%Options{given: given}, recorded, _resume) do
    cond do
      is_binary(given[:system]) ->
        given[:system]

      is_map(recorded["harness_assembly"]) and
          Map.has_key?(recorded["harness_assembly"], "system") ->
        recorded["harness_assembly"]["system"]

      Map.has_key?(recorded, "system") ->
        recorded["system"]

      true ->
        :default
    end
  end

  # `:tools` is an explicit host override, new session or resume. Otherwise a
  # resume starts from the names its transcript recorded, so a scout or a
  # network tool joins *those*; a transcript that recorded none is equipped
  # like a new session.
  defp tools(opts, _recorded, nil), do: Keyword.get(opts, :tools)

  defp tools(opts, recorded, _resume) do
    case Keyword.fetch(opts, :tools) do
      {:ok, tools} -> tools
      :error -> recorded |> Map.get("tools") |> restored_tools()
    end
  end

  defp restored_tools(nil), do: nil
  defp restored_tools(names) when is_list(names), do: Enum.map(names, &tool_module/1)

  defp tool_module(module) when is_atom(module), do: module
  defp tool_module(name) when is_binary(name), do: String.to_existing_atom(name)

  # The mode's extensions, tagged so `standard_tools/2` can take the ones that
  # shape the catalog. See the module documentation for the order. `loaded`
  # is what `loaded/2` read from disk, already a list of specs; it goes after
  # the shipped list and before the host's, which is the seam where a person
  # can wrap what `lmx` did and a host can still wrap what the person did.
  defp extensions(options, opts, context, loaded) do
    disabled = disabled(options)

    profile? =
      Keyword.has_key?(opts, :profile) or options.extension_profile != nil or options.build_ext

    with {:ok, web} <- web_spec(options, context, disabled, profile?),
         {:ok, systemone} <- systemone_spec(options, disabled) do
      elixir = elixir(options, context)
      recipe = recipe(options, opts, context, web, elixir, profile?)

      {:ok,
       recipe
       |> with_lmx_equipment(options, context, catalog?(context, elixir, profile?))
       |> Enum.concat(a2ui: if(Keyword.get(opts, :a2ui, false), do: Lemieux.Extensions.A2UI))
       |> Enum.concat(Enum.map(loaded, &{:loaded, &1.spec}))
       |> Enum.concat(checkpoints: checkpoints(options, context))
       |> Enum.reject(fn {name, spec} ->
         is_nil(spec) or MapSet.member?(disabled, Atom.to_string(name))
       end)
       |> Enum.concat(Enum.map(Keyword.get(opts, :extensions, []), &{:host, &1}))
       |> then(fn extensions ->
         if systemone, do: extensions ++ [{:systemone, systemone}], else: extensions
       end)}
    end
  end

  defp web_spec(options, context, disabled, profile?) do
    if MapSet.member?(disabled, "web") or (profile? and Options.automatic_web?(options)),
      do: {:ok, nil},
      else: web(options, context)
  end

  defp systemone_spec(options, disabled) do
    if MapSet.member?(disabled, "systemone_compaction"),
      do: {:ok, nil},
      else: SystemOneCompaction.spec(options.config, options.ixway)
  end

  # What lmx adds to the defaults is for sessions lmx is equipping: not over
  # an explicit extension profile, whose catalog and prompt are the thing
  # being run (`--extension-profile`, the builder), and the machine-reading
  # ones — the environment block, verification after edits — not under
  # `--config none` either, which runs hermetically.
  defp recipe(options, opts, context, web, elixir, profile?) do
    personal? = not profile? and not is_nil(options.host.state_dir)

    Lemieux.Extensions.coding(context.model, context.provider,
      hooks: hooks(options, opts, context),
      mcp: mcp(options, context),
      profile: Keyword.get(opts, :profile),
      interactive: interactive?(options, context),
      web: web,
      elixir: elixir,
      workspace: workspace(opts),
      environment_context: personal?,
      # Reads nothing from the machine, so unlike verify it does not need a
      # state directory: `--config none` runs keep it too.
      continuation: if(not profile?, do: continuation(options)),
      # Says nothing without a limit, and `lmx run --max-requests` is one.
      budget: not profile?,
      verify: if(personal?, do: verify(options, checkpoints_dir(options, disabled(options)))),
      a2a: a2a(options),
      delegate: delegate?(options, context),
      cwd: context.cwd,
      subagent_options: Keyword.get(opts, :subagent_options, []),
      scout_model: Config.get(options.config, "scout_model")
    )
  end

  # The Elixir profile replaces the catalog with the evaluation tool; the
  # search and plan tools beside it would widen the one narrow mode.
  defp catalog?(context, elixir, profile?),
    do: not profile? and context.new? and not elixir_profile?(elixir)

  defp with_lmx_equipment(recipe, options, context, catalog?) do
    recipe
    |> insert_after([:hooks], config_hooks: config_hooks(options, context))
    |> insert_after([:config_hooks, :hooks], permissions: permissions_spec(options, context))
    |> insert_after([:mcp], mcp_discovery: mcp_discovery(options, recipe))
    |> insert_after(@equipment_anchors,
      search: if(catalog?, do: Search),
      apply_patch: if(catalog?, do: {ApplyPatch, model: context.model}),
      planning: if(catalog?, do: Lemieux.Extensions.Planning)
    )
  end

  defp elixir_profile?(nil), do: false
  defp elixir_profile?({_module, opts}), do: Keyword.get(opts, :profile, true)

  defp disabled(options), do: MapSet.new(Config.get(options.config, "disabled_extensions", []))

  # Places `entries` after the last of `anchors` present in `recipe`, or at
  # the front when none is: hooks first, then the policy that reads what they
  # decided.
  defp insert_after(recipe, anchors, entries) do
    index =
      recipe
      |> Enum.with_index()
      |> Enum.filter(fn {{name, _spec}, _index} -> name in anchors end)
      |> Enum.map(fn {_entry, index} -> index + 1 end)
      |> Enum.max(fn -> 0 end)

    {before, rest} = Enum.split(recipe, index)
    before ++ entries ++ rest
  end

  # The config file's options over the recipe's (none, for `true`).
  # `"verify": false` and `"verify": {"enabled": false}` both leave it out.
  # Where checkpoints are recorded, the check is recorded with them, so
  # `/undo` takes back what it changed along with the turn's edits
  # (`Lemieux.Extensions.Verify`, "Inside the undo net"); withholding
  # `checkpoints` withholds that too.
  defp verify(options, checkpoints) do
    case Config.get(options.config, "verify", true) do
      false -> nil
      %{"enabled" => false} -> nil
      %{} = settings -> settings |> verify_options() |> with_checkpoints(checkpoints)
      _true -> with_checkpoints([], checkpoints)
    end
  end

  defp with_checkpoints(verify_options, nil), do: verify_options
  defp with_checkpoints(verify_options, dir), do: Keyword.put(verify_options, :checkpoints, dir)

  defp verify_options(settings) do
    [
      command: Map.get(settings, "command", :auto),
      max_continuations: Map.get(settings, "max_continuations"),
      timeout_ms: Map.get(settings, "timeout_ms")
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # The same shape as verify's: `"continuation": false` and
  # `{"enabled": false}` leave it out, an object sets its allowances.
  defp continuation(options) do
    case Config.get(options.config, "continuation", true) do
      false ->
        nil

      %{"enabled" => false} ->
        nil

      %{} = settings ->
        [
          max_continuations: Map.get(settings, "max_continuations"),
          max_output_continuations: Map.get(settings, "max_output_continuations"),
          completion_check: Map.get(settings, "completion_check")
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      _true ->
        true
    end
  end

  defp a2a(options) do
    case Config.get(options.config, "a2a_peers", %{}) do
      peers when map_size(peers) == 0 ->
        nil

      peers ->
        {Lemieux.Extensions.A2A, peers: peers, commands: [Lemieux.Conversation.Command.A2A]}
    end
  end

  # An explicit `hooks:` from the host is the host's policy and wins over a
  # file named on the command line, as it always has.
  defp hooks(%Options{hooks_config: path}, opts, context) do
    if is_binary(path) and not Keyword.has_key?(opts, :hooks),
      do: {HooksExtension, file: path, credentials: context.credentials}
  end

  # The config file's `"hooks"`, in lmx's versioned form or Claude Code's
  # settings form: the person's own policy, so it is applied as a second
  # source beside `--hooks` rather than instead of it.
  defp config_hooks(options, context) do
    case Config.get(options.config, "hooks") do
      %{} = hooks when map_size(hooks) > 0 ->
        {HooksExtension, config: hooks, credentials: context.credentials}

      _none ->
        nil
    end
  end

  # Servers from three places, each marked with where it came from, which
  # decides what its `${VAR}` references may read (`Lemieux.MCP.expand/2`):
  #
  #   * `--mcp-config FILE` — explicit, and started as named;
  #   * the config file's `"mcp_servers"` — the person's own;
  #   * the repository's `.mcp.json` — only for a new session (a resume keeps
  #     the servers its transcript recorded), and only once trusted: the
  #     extension holds back servers nobody has approved and the screen asks.
  #     With no state directory there is nowhere to remember an approval, so
  #     only `--project-mcp` starts them; `notices/3` says so.
  defp mcp(options, context) do
    explicit = if is_binary(options.mcp_config), do: [options.mcp_config], else: []
    personal = personal_mcp_servers(options.config)
    project = project_mcp_dir(options, context)

    if explicit == [] and personal == [] and is_nil(project) do
      nil
    else
      {MCPExtension,
       files: explicit,
       servers: personal,
       project: project,
       trust: options.host.state_dir,
       trusted?: options.host.project_mcp_trusted}
    end
  end

  defp personal_mcp_servers(config) do
    case Config.get(config, "mcp_servers", %{}) do
      servers when map_size(servers) == 0 -> []
      servers -> MCPConfig.parse(servers, source: "personal")
    end
  end

  @doc """
  The MCP server names the person's own configuration claims.

  A repository server with one of these names is replaced by the person's,
  and is neither started nor asked about (`Lemieux.Extensions.MCP`). A trust
  decision is one digest over the servers it was asked about
  (`Lemieux.MCP.Trust`), so everything that asks — the terminal UI's
  question, `lmx mcp trust`, and `lmx mcp list` reporting the status — has to
  leave out exactly the servers the extension leaves out. A decision recorded
  over a different set never matches: the extension would report the file
  as changed on every start, while the question, finding its own set
  trusted, would never ask again.
  """
  @spec claimed_mcp_names(options :: Options.t()) :: [String.t()]
  def claimed_mcp_names(%Options{} = options),
    do: Enum.map(personal_mcp_servers(options.config), & &1["name"])

  defp project_mcp_dir(%Options{mcp_config: nil} = options, %{new?: true, cwd: cwd}) do
    if Discovery.project_mcp_config(cwd) != nil and
         (options.host.state_dir != nil or options.host.project_mcp_trusted),
       do: cwd
  end

  defp project_mcp_dir(_options, _context), do: nil

  # Schemas are hidden only while the servers' tools would crowd the request;
  # below the threshold they are offered as usual (`Lemieux.Extensions.MCPDiscovery`).
  defp mcp_discovery(options, recipe) do
    mode = Config.get(options.config, "mcp_discovery", "auto")

    if Keyword.has_key?(recipe, :mcp) and mode != "off" do
      {MCPDiscovery,
       [mode: String.to_existing_atom(mode)] ++
         if(options.context_window, do: [context_window: options.context_window], else: [])}
    end
  end

  defp checkpoints(options, _context) do
    case checkpoints_dir(options, MapSet.new()) do
      nil -> nil
      dir -> {Checkpoints, dir: dir, git: true}
    end
  end

  defp checkpoints_dir(%Options{host: %{state_dir: nil}}, _disabled), do: nil

  defp checkpoints_dir(%Options{host: %{state_dir: dir}}, disabled) do
    unless MapSet.member?(disabled, "checkpoints"), do: Path.join(dir, "checkpoints")
  end

  defp permissions_spec(_options, %{permissions: nil}), do: nil

  defp permissions_spec(options, %{permissions: handle} = context) do
    rules = Config.get(options.config, "permissions", %{})

    [
      handle: handle,
      allow: Map.get(rules, "allow", []),
      deny: Map.get(rules, "deny", []),
      ask: Map.get(rules, "ask", [])
    ]
    |> then(fn spec ->
      # Nobody can answer in `lmx run`: a call that would ask is refused,
      # unless the file said otherwise.
      if context.interactive?,
        do: spec,
        else: Keyword.put(spec, :non_interactive, non_interactive(rules))
    end)
    |> then(&{Permissions, &1})
  end

  defp non_interactive(%{"non_interactive" => "allow"}), do: :allow
  defp non_interactive(_rules), do: :deny

  # `ask_user` is equipment for a new catalog. A resume keeps the catalog its
  # transcript recorded — a session started by `lmx run` and resumed here does
  # not gain the tool by being looked at — so the extension applies only when
  # the catalog is being equipped anyway: a new session, a transcript that
  # recorded no tools, or `--elixir` replacing them.
  defp interactive?(%Options{given: given}, %{interactive?: true} = context) do
    context.new? or given[:elixir] == true or not Map.has_key?(context.recorded, "tools")
  end

  defp interactive?(_options, _context), do: false

  # A configured Brave key equips web research in this CLI host. Explicit
  # options can still disable search and fetch independently. The tools
  # re-equip a resume using the current host's route, but research guidance
  # only joins a new prompt: a resume keeps its recorded system text.
  defp web(%Options{web_search: nil, web_fetch: false}, _context), do: {:ok, nil}
  defp web(%Options{web_search: nil, web_fetch: true}, _context), do: {:ok, {Web, fetch: true}}

  defp web(%Options{web_search: "brave", web_fetch: fetch, config: config}, context) do
    with {:ok, api_key} <- web_search_api_key(config, "brave", "BRAVE_SEARCH_API_KEY") do
      backend = Brave.new(api_key: api_key)

      {:ok,
       {Web,
        search: {Brave, backend},
        search_cost_usd: Brave.request_cost_usd(backend),
        fetch: fetch,
        guide: context.new?}}
    end
  end

  # An explicitly empty environment key disables the saved fallback, as it
  # does for model providers; otherwise an old file key could silently defeat
  # the operator's attempt to disable a credential for this process.
  defp web_search_api_key(config, provider, name) do
    case System.get_env(name) || Config.web_search_api_key(config, provider) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _missing ->
        {:error,
         "--web-search #{provider} needs #{name} or web_search_providers.#{provider}.api_key in config.json"}
    end
  end

  # `--elixir` narrows the catalog to the evaluation tool and brings the
  # commands that go with it (`/elixir`, `/attach`, `/detach`). A resume
  # narrows only when the flag was typed: the resolved value is a default,
  # and a default does not rewrite a transcript.
  #
  # Without the flag, an interactive host opened on an Elixir project — a
  # `mix.exs` in the working directory or above it, up to the repository
  # root — offers the commands without the profile, so `/elixir` is there to
  # switch to it, as it always was for the people who used it; everywhere
  # else those three commands meant nothing and are no longer listed.
  # `"disabled_extensions": ["elixir"]` withholds them in Elixir projects too.
  defp elixir(options, context) do
    cond do
      elixir_requested?(options, context) ->
        {Lemieux.Extensions.Elixir, commands: Builtin.elixir()}

      context.interactive? and elixir_project?(context.cwd) ->
        {Lemieux.Extensions.Elixir, profile: false, commands: Builtin.elixir()}

      true ->
        nil
    end
  end

  defp elixir_requested?(%Options{elixir: true}, %{new?: true}), do: true
  defp elixir_requested?(%Options{given: given}, %{new?: false}), do: given[:elixir] == true
  defp elixir_requested?(_options, _context), do: false

  defp elixir_project?(cwd), do: cwd |> Path.expand() |> elixir_project?(20)

  defp elixir_project?(_dir, 0), do: false

  defp elixir_project?(dir, depth) do
    cond do
      File.regular?(Path.join(dir, "mix.exs")) -> true
      File.exists?(Path.join(dir, ".git")) -> false
      Path.dirname(dir) == dir -> false
      true -> elixir_project?(Path.dirname(dir), depth - 1)
    end
  end

  defp workspace(opts) do
    case Keyword.get(opts, :workspace) do
      %Discovery{} = workspace -> {Workspace, workspace: workspace}
      _none -> nil
    end
  end

  # On by default for a new session — see `Lemieux.CLI.Options` — and on a
  # resume only when the flag was typed, because the default belongs to the
  # command opening a new session rather than to a transcript being continued.
  # `:subagent_options` is this host's own option — scripted child providers
  # in tests, a policy map — folded into the tool rather than passed on.
  defp delegate?(%Options{delegate: delegate?}, %{new?: true}), do: delegate?
  defp delegate?(%Options{given: given}, _context), do: given[:delegate] == true

  @doc """
  Turns the options that opened an interactive host into an exact resume.

  Flags such as `--model`, `--system` and `--mcp-config` were instructions for
  the session that the host initially opened. Reapplying them when `/resume`
  selects another transcript would silently rewrite that stored session's
  configuration. Network routes, credentials and hooks remain on `options`
  because those belong to the host doing the resuming now.
  """
  @spec resume_options(options :: Options.t(), id :: String.t()) :: Options.t()
  def resume_options(%Options{} = options, id) when is_binary(id) do
    %{options | resume: id, system: nil, mcp_config: nil, given: []}
  end

  # Resolved once here rather than in `Lemieux.resume_session/1`: the recorded
  # configuration and the session registry both address the transcript by id, and
  # a shorthand reaching either reads as a session with no recorded configuration
  # — which silently resumes on this build's default model.
  defp resolved_resume(_store, nil), do: {:ok, nil}
  defp resolved_resume(store, reference), do: Shorthand.resolve(store, reference)

  @doc """
  The options a command starts from, with the repository's MCP configuration
  left for the trust gate.

  This used to copy the repository's `.mcp.json` into `mcp_config`, which
  made it indistinguishable from a file somebody named — and started its
  servers, running their commands, the moment `lmx` opened an unfamiliar
  checkout. The repository's file is now read by `Lemieux.Extensions.MCP`
  itself, under `Lemieux.MCP.Trust`: servers a person has not approved are
  held back with a notice, the terminal UI asks, and `--project-mcp` trusts
  them for one run. A named `--mcp-config`, an explicit `--no-project-mcp`
  and a resume pass through untouched, as before; so does everything else.
  """
  @spec project_mcp(options :: Options.t(), opts :: keyword()) :: Options.t()
  def project_mcp(%Options{} = options, _opts \\ []), do: options

  @doc """
  The permission handle this invocation's sessions share, or `nil` when
  permissions are off — which is the default.

  A mode comes from `--permission-mode` or the config file's
  `"permissions": {"mode": ...}`; `"off"` is the same as none. Created once
  by a host and passed to `prepare/2` as `:permissions`, so a screen that
  switches mode switches it for every session it opens. Remembered rules are
  kept per repository under the state directory, or not at all without one.
  """
  @spec permissions(options :: Options.t(), opts :: keyword()) ::
          {:ok, Permissions.Handle.t() | nil} | {:error, String.t()}
  def permissions(%Options{} = options, opts) do
    case {Keyword.get(opts, :permissions), options.host.permission_mode} do
      {%Permissions.Handle{} = handle, _mode} -> {:ok, handle}
      {_none, mode} when mode in [nil, "off"] -> {:ok, nil}
      {_none, mode} -> Permissions.new(mode: mode, store: permission_store(options, opts))
    end
  end

  defp permission_store(%Options{host: %{state_dir: nil}}, _opts), do: nil

  defp permission_store(%Options{host: %{state_dir: dir}}, opts) do
    workspace = opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Path.expand()
    digest = :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    Path.join([dir, "permissions", digest <> ".json"])
  end

  @doc """
  The credential policy `lmx` runs commands, hooks, the eval node and MCP
  stdio servers under: `{:scrub, allowlist}` unless the config file's
  `"scrub_credentials"` is `false`. See `Lemieux.Environment.Credentials`.
  """
  @spec credential_policy(options :: Options.t(), opts :: keyword()) ::
          Lemieux.Environment.Credentials.policy()
  def credential_policy(%Options{config: config}, _opts) do
    if Config.get(config, "scrub_credentials", true) == false,
      do: :inherit,
      else: {:scrub, Config.get(config, "credential_allowlist", [])}
  end

  # The environment `lmx` gives a session that was not given one: a local
  # environment withholding credentials, inside a sandbox when asked for. A
  # sandbox that was asked for and cannot be had is an error, not a quiet
  # fallback to running unsandboxed. The sandbox hides, beside its own list
  # and the person's `"hidden"`, wherever this run keeps secrets — see
  # `Lemieux.CLI.Runtime.SecretPaths` for why that is not just `~/.lmx`.
  defp environment(options, opts, store) do
    local = Local.new(credentials: credential_policy(options, opts))

    case sandbox_settings(options) do
      nil ->
        {:ok, local}

      settings ->
        cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)
        secrets = SecretPaths.paths(options, store, cwd)

        settings
        |> Keyword.put(:inner, local)
        |> Keyword.update(:hidden, secrets, &(&1 ++ secrets))
        |> Sandbox.new()
        |> case do
          {:ok, sandbox} -> {:ok, sandbox}
          {:error, reason} -> {:error, "the sandbox could not start: #{reason}"}
        end
    end
  end

  defp sandbox_settings(%Options{host: %{sandbox: false}}), do: nil

  defp sandbox_settings(%Options{host: %{sandbox: flag}, config: config}) do
    case {flag, Config.get(config, "sandbox")} do
      {true, %{} = settings} -> sandbox_options(settings)
      {true, _other} -> []
      {nil, true} -> []
      {nil, %{"enabled" => false}} -> nil
      {nil, %{} = settings} -> sandbox_options(settings)
      {nil, _off} -> nil
    end
  end

  defp sandbox_options(settings) do
    [
      backend: settings |> Map.get("backend", "auto") |> String.to_existing_atom(),
      network: Map.get(settings, "network"),
      localhost: Map.get(settings, "localhost"),
      writable: settings |> Map.get("writable", []) |> Enum.map(&Path.expand/1),
      hidden: settings |> Map.get("hidden", []) |> Enum.map(&Path.expand/1)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # What only the host knows is worth a line at startup: fields the config
  # file had that this build ignored, and repository servers that could not
  # even be offered because there is nowhere to remember approving them.
  defp notices(options, _opts, context) do
    Config.warnings(options.config) ++ hermetic_mcp_notice(options, context)
  end

  defp hermetic_mcp_notice(
         %Options{mcp_config: nil, host: %{state_dir: nil}} = options,
         %{new?: true} = context
       ) do
    if Discovery.project_mcp_config(context.cwd) != nil and not options.host.project_mcp_trusted,
      do: [
        "The repository's MCP servers were not started: with --config none there is no " <>
          "record of trusting them. Pass --project-mcp to start them for this run."
      ],
      else: []
  end

  defp hermetic_mcp_notice(_options, _context), do: []

  # What the terminal UI needs to ask about the repository's servers. It asks
  # again itself, off the render loop (`Lemieux.TUI.Trust`), so it is handed
  # the claimed names too: see `claimed_mcp_names/1` for what a question over
  # a different set of servers would record.
  defp mcp_trust(%Options{mcp_config: nil, host: %{state_dir: dir}} = options, %{
         new?: true,
         cwd: cwd
       })
       when is_binary(dir) do
    unless options.host.project_mcp_trusted do
      claimed = claimed_mcp_names(options)

      case MCPExtension.project_trust(cwd, dir, except: claimed) do
        nil -> nil
        pending -> Map.merge(pending, %{store: dir, cwd: cwd, except: claimed})
      end
    end
  end

  defp mcp_trust(_options, _context), do: nil

  # Startup never waits on a browser: a server that needs OAuth consent comes
  # up as needing it, and `/mcp` finishes the flow when somebody is there.
  # The credential policy withholds keys from stdio servers the same way it
  # does from commands; names a person approved when trusting the repository
  # may still be expanded into its configuration.
  defp mcp_connect_opts(options, context) do
    [
      interactive_auth: false,
      credentials: context.credentials,
      allow_env: approved_env(options, context)
    ]
  end

  defp approved_env(%Options{host: %{state_dir: dir}} = options, %{new?: true, cwd: cwd})
       when is_binary(dir) do
    claimed = claimed_mcp_names(options)

    with file when is_binary(file) <- Discovery.project_mcp_config(cwd),
         {:ok, servers} <- MCPConfig.read(file, source: "project") do
      servers = Enum.reject(servers, &(&1["name"] in claimed))
      Trust.allowed_env(dir, Path.dirname(file), servers)
    else
      _nothing -> []
    end
  end

  defp approved_env(_options, _context), do: []

  @doc """
  Discovers the workspace the terminal UI applies: persona, repository
  instructions, memory, Agent Skills and the selected plugins.

  Public so a host other than the terminal UI can apply the same workspace
  the same way. Personal instruction files and skills are read unless
  `:personal?` says otherwise, and so are the system skill roots and the
  config's disabled skill names (`Lemieux.CLI.Skills.discovery_options/2`),
  which `lmx skills` inspects through this same function.

  Without `:personal?`, they are read only when the invocation has a state
  directory, as `with_workspace/2` decides for `lmx run`. The default used
  to be `true`, so the terminal UI under `--config none` composed over your
  `~/.claude/CLAUDE.md` and personal skills while `lmx run` and the
  documentation said `--config none` reads none of them.
  """
  @spec discover_workspace(options :: Options.t(), opts :: keyword()) ::
          {:ok, Discovery.t()} | {:error, String.t()}
  def discover_workspace(%Options{} = options, opts) do
    personal? = Keyword.get(opts, :personal?, is_binary(options.host.state_dir))

    ([
       cwd: Keyword.get_lazy(opts, :cwd, &File.cwd!/0),
       supplied: trusted(options),
       bundled_skills?: true,
       skill_dirs: options.skill_dirs,
       plugin_dirs: options.plugin_dirs,
       marketplaces: options.marketplaces,
       plugins: options.plugins,
       marketplace_fetch: Keyword.get(opts, :marketplace_fetch, []),
       personal?: personal?
     ] ++ Skills.discovery_options(options, Keyword.put(opts, :personal?, personal?)))
    |> maybe_workspace_option(:personal_dir, opts)
    |> maybe_workspace_option(:claude_personal_dir, opts)
    |> maybe_workspace_option(:codex_personal_dir, opts)
    |> maybe_workspace_option(:agents_personal_dir, opts)
    |> maybe_workspace_option(:home, opts)
    |> Workspace.init()
  end

  defp maybe_workspace_option(workspace_opts, key, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Keyword.put(workspace_opts, key, value)
      :error -> workspace_opts
    end
  end

  @doc """
  The repository components this invocation has already been told to trust.

  What `Lemieux.Extensions.Workspace.Discovery.notices/2` takes as `:supplied`, so that a
  warning whose own advice has been followed is not repeated. Here rather than
  in either host because both of them ask, and an answer that drifted between
  the screen and the line would be a warning that appears in one and not the
  other.
  """
  @spec trusted(options :: Options.t()) :: [:hooks]
  def trusted(%Options{hooks_config: nil}), do: []
  def trusted(%Options{}), do: [:hooks]

  # The configuration the transcript last recorded, or nothing for a new
  # session and for a transcript written before lemieux recorded any.
  defp recorded_config(_store, nil), do: %{}

  defp recorded_config(store, id) do
    with {:ok, entries} <- Lemieux.Store.read(store, id),
         entry when not is_nil(entry) <-
           entries |> Enum.filter(&(&1.type == :session)) |> List.last() do
      entry.payload
    else
      _otherwise -> %{}
    end
  end

  @doc """
  How `lmx` authorizes against MCP servers that want OAuth.

  Built for every session, not only ones with servers configured, because it
  costs a struct and the alternative is a flag that works or does not depending
  on what else was typed.

  With the default token file, the tokens an earlier build kept in
  `~/.lemieux/credentials.json` are moved there the first time the store is
  used (see `Lemieux.CLI.OAuth`); a file somebody named is theirs and nothing
  is moved into it.
  """
  @spec auth(options :: Options.t()) :: Auth.t()
  def auth(%Options{} = options) do
    Auth.new(
      store: credential_store(options.credentials),
      redirect_uri: "http://127.0.0.1:#{options.oauth_callback_port}/callback",
      redirect: &OAuth.redirect/2,
      clients: options.oauth_clients,
      # What a person reads on the consent screen. No `client_id_metadata_url` yet:
      # CIMD needs a JSON document hosted at a stable HTTPS URL somebody owns, which is
      # a commitment rather than a line of code. Until then `lmx` registers dynamically
      # where it can and takes a hand-made client id where it cannot.
      client_name: "lmx"
    )
  end

  @doc false
  # Public so the one-time move from the old default is tested without a
  # session: the store a token file gets, moving the old default into lmx's
  # own only when the file is lmx's own.
  @spec credential_store(path :: Path.t()) :: Lemieux.MCP.Auth.Store.t()
  def credential_store(path) when is_binary(path) do
    if path == OAuth.default_store(),
      do: FileStore.new(path, migrate_from: OAuth.legacy_store()),
      else: FileStore.new(path)
  end

  @doc """
  The store a command reads and writes, built from `--sessions-dir` unless the
  caller supplied one.

  Public because `lmx log` and `lmx fork` need exactly this store and nothing
  else about a runtime: they never start a session.
  """
  @spec store(options :: Options.t(), opts :: keyword()) :: Lemieux.Store.t()
  def store(%Options{} = options, opts) do
    Keyword.get_lazy(opts, :store, fn -> JSONL.new(options.sessions_dir) end)
  end

  @doc """
  Stops a session this host has finished with, so its `session_end` hooks run.

  A standalone command ends in `System.halt/1`, which runs nobody's
  `terminate/2`. A session the host merely walked away from therefore never
  reported its end, and a `sessionEnd` command hook given with `--hooks` was
  never run for a completed `lmx run` or an interactive quit — the hook file
  looked wired and did nothing. Every standalone host stops its session here,
  synchronously, before it returns. A session that is already gone is not an
  error: the end it was going to report has happened.
  """
  @spec stop_session(session :: pid()) :: :ok
  def stop_session(session) when is_pid(session) do
    GenServer.stop(session, :normal, @stop_timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Stops every session still running under a mounted runtime.

  For the host whose sessions come and go behind a screen — the TUI opens,
  resumes and switches them — and which therefore has no single pid to stop.
  """
  @spec stop_sessions(supervisor :: atom()) :: :ok
  def stop_sessions(supervisor) when is_atom(supervisor) do
    supervisor
    |> Lemieux.sessions()
    |> Enum.each(fn {_id, session} -> stop_session(session) end)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_new(opts, _key, nil), do: opts
  defp maybe_put_new(opts, key, value), do: Keyword.put_new(opts, key, value)

  @doc """
  Builds the connection `lmx` would use with no flags at all.

  The process environment and the personal configuration file decide the
  route and the credentials, exactly as they do for a session. This is the
  provider that development tooling — the extension workbench, the judge in
  `mix lemieux.eval`, a scaffolded bench script — asks for when it wants
  "whatever this machine is set up to use".
  """
  @spec provider() :: Lemieux.Provider.t()
  def provider do
    case Options.parse([]) do
      {:ok, options} -> provider(options)
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Builds the CLI connection with its runtime route and credential policy:
  `provider/2` over the routes the options register — the shipped Ixway
  route when it is configured, and the routes of the extensions the options
  select, loaded from the personal root. A route that cannot be registered,
  or a `--router NAME` nobody registers, raises with the sentence a host
  would print, as `provider/0` raises for options that do not parse: the
  callers of this arity are tooling with no sentence of their own.
  """
  @spec provider(options :: Options.t()) :: Lemieux.Provider.t()
  def provider(%Options{} = options) do
    with {:ok, loaded} <- loaded(options, []),
         {:ok, routes} <- routes(options, [], loaded) do
      provider(options, routes)
    else
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Builds the connection `lmx run` sends through, given the registered routes.

  `--ixway` and `--router NAME` select one route as the sole connection:
  its models alone, no direct credential to fall back on. Otherwise the
  direct connection carries every registered route beside it
  (`Lemieux.CLI.ProviderMux`), each answering for the models under its own
  name, and none when no route is registered.
  """
  @spec provider(options :: Options.t(), routes :: Routes.t()) :: Lemieux.Provider.t()
  def provider(%Options{} = options, routes) when is_list(routes) do
    cond do
      is_binary(options.ixway) -> sole(routes, "ixway", options)
      is_binary(options.host.route) -> sole(routes, options.host.route, options)
      routes == [] -> direct_provider(options)
      true -> ProviderMux.new(routes, direct_provider(options))
    end
  end

  # `Routes.selected/2` has already refused a `--router NAME` nobody
  # registered where a host prepares; Ixway is built on the spot for a
  # caller that passed a list without it.
  defp sole(routes, name, options) do
    case Routes.fetch(routes, name) do
      {:ok, provider} -> provider
      :error when name == "ixway" -> Routes.ixway(options)
      :error -> raise ArgumentError, Routes.unregistered(name, routes)
    end
  end

  @doc "Builds the TUI connection with the shipped routes alone: `tui_provider/2` over `Lemieux.CLI.Routes.builtin/1`."
  @spec tui_provider(options :: Options.t()) :: Lemieux.Provider.t()
  def tui_provider(%Options{} = options), do: tui_provider(options, Routes.builtin(options))

  @doc """
  Builds the TUI connection: the direct providers with configured
  credentials beside every registered route, so a person can switch between
  them with `/provider`, and a shared key blocked from advertising a second
  provider.
  """
  @spec tui_provider(options :: Options.t(), routes :: Routes.t()) :: Lemieux.Provider.t()
  def tui_provider(%Options{} = options, routes) when is_list(routes) do
    direct = direct_provider(options)

    case {routes, shadowed_providers(options.config)} do
      {[], []} -> direct
      {routes, blocked} -> ProviderMux.new(routes, direct, blocked_providers: blocked)
    end
  end

  @doc """
  Readies the route the TUI's start model names before the session's model
  is selected, so the route's discovery overlaps the screen's own work; a
  model on no route leaves the provider as it is.
  """
  @spec discover_tui_provider(provider :: Lemieux.Provider.t(), model :: String.t()) ::
          {:ok, Lemieux.Provider.t()} | {:error, term()}
  def discover_tui_provider({ProviderMux, _state} = provider, model) when is_binary(model),
    do: provider |> ProviderMux.ready(ModelSpec.provider(model)) |> named_key()

  def discover_tui_provider(provider, model) when is_binary(model),
    do: provider |> ReqLLMProvider.ready() |> named_key()

  @doc "Readies every registered route of a TUI connection before a model is selected."
  @spec discover_tui_provider(provider :: Lemieux.Provider.t()) ::
          {:ok, Lemieux.Provider.t()} | {:error, term()}
  def discover_tui_provider({ProviderMux, _state} = provider),
    do: provider |> ProviderMux.discover() |> named_key()

  def discover_tui_provider(provider), do: {:ok, provider}

  # Several ReqLLM logical providers can read one environment variable. A
  # person who saved a key under one name has selected that route, not every
  # other API sharing the variable (the three Z.AI routes do this today).
  # Unrelated ambient credentials remain discoverable in the TUI.
  defp shadowed_providers(config) do
    configured = config |> Config.api_keys() |> Map.keys() |> MapSet.new()
    providers = ReqLLM.Providers.list()

    selected_envs =
      providers
      |> Enum.filter(&MapSet.member?(configured, Atom.to_string(&1)))
      |> Enum.map(&ReqLLM.Providers.get_env_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    providers
    |> Enum.reject(&MapSet.member?(configured, Atom.to_string(&1)))
    |> Enum.filter(fn provider ->
      case ReqLLM.Providers.get_env_key(provider) do
        nil -> false
        env -> MapSet.member?(selected_envs, env)
      end
    end)
    |> Enum.map(&Atom.to_string/1)
  end

  defp direct_provider(%Options{} = options) do
    # Keep the command router usable from `mix run` and other callers that did
    # not boot dependencies. In the release this is already started and the
    # call is harmless.
    {:ok, _started} = Application.ensure_all_started(:req_llm)

    # One provider instance survives `/model` and `/provider` changes, so the timeout
    # policy goes on the host instance rather than being chosen from the startup
    # model — otherwise a session opened on Anthropic silently regains req_llm's
    # 30-second transport timeout after switching to local Ollama. Semantic
    # inactivity stays bounded while transport inactivity is allowed during long cold
    # loads, prefill and reasoning.
    keys = Config.api_keys(options.config)

    []
    |> maybe_put(:base_url, options.base_url)
    |> maybe_put(:api_key_defaults, if(map_size(keys) == 0, do: nil, else: keys))
    |> Keyword.merge(
      ModelCatalog.provider_options() ++
        [receive_timeout: :infinity, stream_idle_timeout: :timer.minutes(5)]
    )
    |> ReqLLMProvider.new()
  end
end

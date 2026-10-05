defmodule Lemieux.Extensions.Permissions do
  @moduledoc """
  Asks before the agent changes things, the way Claude Code and Codex do.

  The core has no permission system (`Lemieux.Hooks` says why); this is the
  shipped one, built on the same `before_tool_call` seam any host can use. It
  answers every call with allow, deny, or `{:pending, …}` — the asynchronous
  approval a host renders as a card and answers with
  `Lemieux.Session.resolve_tool/3`.

  ## Modes

    * `:ask` — ask before anything that changes files, runs commands or
      reaches outside the session, unless a rule allows it.
    * `:accept_edits` — file edits in the session directory run unasked;
      commands and everything else still ask.
    * `:auto` — when the session's environment is a sandbox
      (`Lemieux.Environment.Sandbox`), commands and file edits run unasked,
      because the sandbox is what bounds them; without one it behaves like
      `:accept_edits`. Tools that run *beside* the sandbox — MCP tools, web
      fetches, the Elixir evaluator — still ask.
    * `:full_auto` — nothing asks. Deny rules still apply.
    * `:read_only` — tools that change things are refused, unless an allow
      rule names them.

  Whatever the mode, these are never asked about: tools whose descriptor
  declares them read-only (`read`, `grep`, `glob`, the read-only scout),
  tools whose descriptor policy says `"approval" => "never"`, tools that only
  touch the session's own state (the todo list) and `ask_user`, which is
  already a question. A descriptor that says `"approval" => "always"` is
  asked about in every mode but `:full_auto`.

  ## Rules

  `:allow`, `:deny` and `:ask` take rule strings in Claude Code's syntax —
  `"Bash(npm run test:*)"`, `"Edit(src/**)"`, `"Read(.env)"`,
  `"mcp__github"` — described in `Lemieux.Extensions.Permissions.Rule`. The
  order of precedence is: deny rules, then the mode's own refusals, then ask
  rules, then everything that allows. So `deny: ["Bash(git push:*)"]` holds
  in `:full_auto`, and `ask: ["Read(.env)"]` asks even though reading is
  otherwise free.

  A command hook that explicitly approves a call (`permissionDecision:
  "allow"`) counts as an approval here too, when this extension's hook runs
  after it — which is where `Lemieux.Harness.append_hooks/2` puts it.

  Not every command the session runs is the model's tool call. The project
  check `Lemieux.Extensions.Verify` runs after edits is put to this policy as
  the `bash` call that would run it, so `"Bash(make test)"` allows it, a
  `Bash` deny rule refuses it, and `:accept_edits` asks about it.

  ## The handle

  A host that lets a person change the mode mid-session, or offers "always
  allow" on the approval card, creates a handle with `new/1` and passes it in
  as `:handle`. The mode lives in an `:atomics` array: shared memory with no
  owner process, so the extension adds nothing to supervise and a session's
  tool tasks read the current mode without a message round trip. Remembered
  rules live in the `:store` file (`Lemieux.Extensions.Permissions.Store`),
  read on each decision, so a rule remembered by one session applies to the
  next call in every session sharing the file.

  ## When nobody can answer

  A headless host has no card to show. `:non_interactive` says what a
  question becomes there: `:deny` (the call is refused with a reason that
  names the rule or mode that would allow it) or `:allow`. A session with no
  process to park on is treated as `:deny`.

  ## The pending payload

  A question is `{:pending, %{permission: details}}`, which
  `Lemieux.Hooks` merges into the call the session emits as
  `{:tool_approval, call}`. `details` is JSON-shaped:

      %{
        "mode" => "ask",
        "reason" => "bash runs a command",
        "suggestions" => [
          %{"label" => "Always allow `mix test …` in this repository",
            "rule" => "Bash(mix test:*)"},
          %{"label" => "Allow file edits for the rest of this session",
            "mode" => "accept_edits"}
        ]
      }

  A suggestion with `"rule"` is applied with `remember/2` (it needs a
  `:store`), one with `"mode"` with `set_mode/2`; either way the host then
  resolves the call itself.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Environment.Sandbox
  alias Lemieux.Extensions.Permissions.Rule
  alias Lemieux.Extensions.Permissions.Shell
  alias Lemieux.Extensions.Permissions.Store
  alias Lemieux.Harness
  alias Lemieux.Hooks.Claude

  @typedoc "How much the agent may do unasked."
  @type mode :: :ask | :accept_edits | :auto | :full_auto | :read_only

  @modes [:ask, :accept_edits, :auto, :full_auto, :read_only]

  # The order a "next mode" key walks. Full auto is left out on purpose: a
  # mode that asks nothing should be a deliberate choice, not one keypress
  # past the mode that asks about edits.
  @cycle [:ask, :accept_edits, :auto, :read_only]

  # Effect classes that only look, and resource types that live and die with
  # the session. Neither changes anything a person would want to approve.
  @reading_classes ["read", "delegated_read", "attention"]
  @session_resources ["human_attention", "agent_tree"]

  defmodule Handle do
    @moduledoc """
    What a host holds to change a running permission policy: the current mode
    and where remembered rules are kept. Create it with
    `Lemieux.Extensions.Permissions.new/1`.
    """

    @enforce_keys [:mode, :store]
    defstruct [:mode, :store]

    @type t :: %__MODULE__{mode: :atomics.atomics_ref(), store: Path.t() | nil}
  end

  @type state :: %{
          handle: Handle.t(),
          allow: [Rule.t()],
          deny: [Rule.t()],
          ask: [Rule.t()],
          non_interactive: :deny | :allow | nil
        }

  # --- The handle -------------------------------------------------------------

  @doc """
  Creates a handle.

    * `:mode` — the starting mode (default `:ask`); Claude's names
      (`"default"`, `"acceptEdits"`, `"plan"`, `"bypassPermissions"`) are
      accepted too.
    * `:store` — the file remembered rules are kept in, or `nil`.
  """
  @spec new(opts :: keyword()) :: {:ok, Handle.t()} | {:error, String.t()}
  def new(opts \\ []) when is_list(opts) do
    with {:ok, mode} <- parse_mode(Keyword.get(opts, :mode, :ask)),
         {:ok, store} <- store(Keyword.get(opts, :store)) do
      atomics = :atomics.new(1, signed: false)
      :atomics.put(atomics, 1, index(mode))
      {:ok, %Handle{mode: atomics, store: store}}
    end
  end

  @doc "The handle's current mode."
  @spec mode(handle :: Handle.t()) :: mode()
  def mode(%Handle{mode: atomics}), do: Enum.at(@modes, :atomics.get(atomics, 1) - 1)

  @doc "Changes the mode every session using `handle` decides by, from the next call on."
  @spec set_mode(handle :: Handle.t(), mode :: mode() | String.t()) :: :ok | {:error, String.t()}
  def set_mode(%Handle{mode: atomics}, mode) do
    with {:ok, mode} <- parse_mode(mode) do
      :atomics.put(atomics, 1, index(mode))
    end
  end

  @doc """
  Moves to the next mode in `#{inspect(@cycle)}` and returns it; from
  `:full_auto`, back to `:ask`.
  """
  @spec cycle(handle :: Handle.t()) :: mode()
  def cycle(%Handle{} = handle) do
    next =
      case Enum.find_index(@cycle, &(&1 == mode(handle))) do
        nil -> :ask
        index -> Enum.at(@cycle, rem(index + 1, length(@cycle)))
      end

    :ok = set_mode(handle, next)
    next
  end

  @doc "Every mode, in the order a person would read them."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "A short label for `mode`, for a status line."
  @spec label(mode :: mode()) :: String.t()
  def label(:ask), do: "ask"
  def label(:accept_edits), do: "accept edits"
  def label(:auto), do: "auto"
  def label(:full_auto), do: "full auto"
  def label(:read_only), do: "read-only"

  @doc """
  Remembers `rule` in the handle's store, so it allows from now on.

  An invalid rule is refused rather than written; a handle without a store
  cannot remember anything, and says so.
  """
  @spec remember(handle :: Handle.t(), rule :: String.t()) :: :ok | {:error, String.t()}
  def remember(%Handle{store: nil}, _rule),
    do: {:error, "this session has nowhere to remember permission rules"}

  def remember(%Handle{store: store}, rule) when is_binary(rule) do
    with {:ok, _rule} <- Rule.parse(rule), do: Store.add(store, rule)
  end

  @doc "Forgets a remembered rule."
  @spec forget(handle :: Handle.t(), rule :: String.t()) :: :ok | {:error, String.t()}
  def forget(%Handle{store: nil}, _rule), do: :ok
  def forget(%Handle{store: store}, rule) when is_binary(rule), do: Store.remove(store, rule)

  @doc "The rules remembered in the handle's store."
  @spec remembered(handle :: Handle.t()) :: [String.t()]
  def remembered(%Handle{store: store}) do
    case Store.read(store) do
      {:ok, rules} -> rules
      {:error, _reason} -> []
    end
  end

  # --- The extension ----------------------------------------------------------

  @impl Lemieux.Extension
  @spec init(opts :: keyword()) :: {:ok, state()} | {:error, String.t()}
  def init(opts) when is_list(opts) do
    with {:ok, handle} <- handle(opts),
         {:ok, rules} <- rules(opts),
         {:ok, non_interactive} <- non_interactive(Keyword.get(opts, :non_interactive)) do
      {:ok, Map.merge(rules, %{handle: handle, non_interactive: non_interactive})}
    end
  end

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, state),
    do:
      Harness.append_hooks(harness,
        before_tool_call: fn call, context -> check(state, call, context) end
      )

  @impl Lemieux.Extension
  def describe(state) do
    %{
      "mode" => Atom.to_string(mode(state.handle)),
      "allow" => Enum.map(state.allow, & &1.source),
      "deny" => Enum.map(state.deny, & &1.source),
      "ask" => Enum.map(state.ask, & &1.source),
      "store" => state.handle.store,
      "non_interactive" => state.non_interactive && Atom.to_string(state.non_interactive)
    }
  end

  defp handle(opts) do
    case Keyword.fetch(opts, :handle) do
      {:ok, %Handle{} = handle} ->
        if Keyword.has_key?(opts, :mode) or Keyword.has_key?(opts, :store),
          do: {:error, "pass :mode and :store to Permissions.new/1 when you supply a :handle"},
          else: {:ok, handle}

      {:ok, other} ->
        {:error, "expected a Permissions handle, got: #{inspect(other)}"}

      :error ->
        new(Keyword.take(opts, [:mode, :store]))
    end
  end

  # Keyword lists, or one map in the shape of Claude Code's `permissions`
  # object — `%{"allow" => [...], "deny" => [...], "ask" => [...]}`.
  defp rules(opts) do
    settings = Keyword.get(opts, :rules, %{})
    list = fn key -> Keyword.get(opts, key, []) ++ Map.get(settings, Atom.to_string(key), []) end

    with {:ok, allow} <- Rule.parse_all(list.(:allow)),
         {:ok, deny} <- Rule.parse_all(list.(:deny)),
         {:ok, ask} <- Rule.parse_all(list.(:ask)) do
      {:ok, %{allow: allow, deny: deny, ask: ask}}
    end
  end

  defp non_interactive(value) when value in [nil, :deny, :allow], do: {:ok, value}
  defp non_interactive("deny"), do: {:ok, :deny}
  defp non_interactive("allow"), do: {:ok, :allow}

  defp non_interactive(other),
    do: {:error, "non_interactive must be :deny, :allow or nil, got: #{inspect(other)}"}

  defp store(nil), do: {:ok, nil}
  defp store(path) when is_binary(path), do: {:ok, Path.expand(path)}
  defp store(other), do: {:error, "a permission store is a path, got: #{inspect(other)}"}

  @doc """
  Parses a mode from its atom, its name, or Claude Code's name for it.
  """
  @spec parse_mode(value :: term()) :: {:ok, mode()} | {:error, String.t()}
  def parse_mode(mode) when mode in @modes, do: {:ok, mode}
  def parse_mode(value) when value in ["ask", "default"], do: {:ok, :ask}
  def parse_mode(value) when value in ["accept_edits", "acceptEdits"], do: {:ok, :accept_edits}
  def parse_mode("auto"), do: {:ok, :auto}
  def parse_mode(value) when value in ["full_auto", "bypassPermissions"], do: {:ok, :full_auto}
  def parse_mode(value) when value in ["read_only", "plan"], do: {:ok, :read_only}

  def parse_mode(other),
    do: {:error, "unknown permission mode #{inspect(other)}; expected one of #{inspect(@modes)}"}

  defp index(mode), do: Enum.find_index(@modes, &(&1 == mode)) + 1

  # --- The decision -----------------------------------------------------------

  @doc """
  Decides one call: the hook this extension installs.

  Public so a host can put the same policy in front of something that is not
  a session tool call, and so the precedence can be tested without a
  session.
  """
  @spec check(state :: state(), call :: map(), context :: map()) :: Lemieux.Hooks.answer()
  def check(state, call, context) do
    facts = %{
      descriptor: Map.get(context, :tool_descriptor) || %{},
      mode: mode(state.handle),
      allow: state.allow ++ remembered_rules(state.handle)
    }

    # The precedence, in three stages that each decide or pass: refusals
    # (deny rules and the mode's own), then questions a rule or the tool
    # insists on, then everything that allows. What none of them decides is
    # asked about.
    Enum.find_value([&refusal/4, &insisted/4, &allowance/4], fn stage ->
      stage.(state, call, context, facts)
    end) || ask(state, call, context, reason(call, facts.descriptor), facts.mode)
  end

  defp refusal(state, call, context, facts) do
    cond do
      rule = Rule.hit(state.deny, call, context) ->
        {:deny, "denied by the permission rule #{rule.source}"}

      facts.mode == :full_auto ->
        :allow

      facts.mode == :read_only and not permitted_read_only?(call, context, facts) ->
        {:deny,
         "the session is in read-only mode, and #{call.name} changes things; " <>
           "a person can switch modes, or allow it with a rule"}

      true ->
        nil
    end
  end

  defp permitted_read_only?(call, context, facts),
    do: reading?(facts.descriptor, call) or Rule.covers?(facts.allow, call, context)

  defp insisted(state, call, context, facts) do
    cond do
      Map.has_key?(context, :approved_by) ->
        :allow

      rule = Rule.hit(state.ask, call, context) ->
        ask(state, call, context, "the permission rule #{rule.source} asks about it", facts.mode)

      approval(facts.descriptor) == :always ->
        ask(state, call, context, "#{call.name} always asks for approval", facts.mode)

      true ->
        nil
    end
  end

  defp allowance(_state, call, context, facts) do
    cond do
      reading?(facts.descriptor, call) -> :allow
      Rule.covers?(facts.allow, call, context) -> :allow
      sandboxed_auto?(context, facts) -> :allow
      facts.mode in [:auto, :accept_edits] and edits_files?(facts.descriptor) -> :allow
      true -> nil
    end
  end

  defp sandboxed_auto?(context, %{mode: :auto, descriptor: descriptor}),
    do: confined?(descriptor) and Sandbox.sandboxed?(Map.get(context, :environment))

  defp sandboxed_auto?(_context, _facts), do: false

  defp remembered_rules(handle) do
    case handle |> remembered() |> Rule.parse_all() do
      {:ok, rules} -> rules
      {:error, _invalid} -> []
    end
  end

  defp ask(%{non_interactive: :allow}, _call, _context, _reason, _mode), do: :allow

  defp ask(%{non_interactive: non_interactive}, call, context, reason, mode)
       when non_interactive == :deny or not is_map_key(context, :session) do
    {:deny,
     "#{call.name} needs approval (#{reason}) in #{label(mode)} mode, and nobody can approve " <>
       "it in this session; allow it with a permission rule or run in a mode that permits it"}
  end

  defp ask(_state, call, context, reason, mode) do
    {:pending,
     %{
       permission: %{
         "mode" => Atom.to_string(mode),
         "reason" => reason,
         "suggestions" => suggestions(call, context)
       }
     }}
  end

  # A bash call without a command polls or cancels a background task that was
  # itself approved when it started; asking again would ask about reading.
  defp reading?(_descriptor, %{name: "bash", arguments: arguments}) when is_map(arguments),
    do: not is_binary(arguments["command"])

  defp reading?(descriptor, _call) do
    effects = Map.get(descriptor, "effects", %{})
    class = Map.get(effects, "class")
    resources = Map.get(effects, "resource_types", [])

    class in @reading_classes or approval(descriptor) == :never or
      (resources != [] and Enum.all?(resources, &session_resource?/1))
  end

  defp session_resource?("session_" <> _rest), do: true
  defp session_resource?(resource), do: resource in @session_resources

  # `Lemieux.Tool.Descriptor.approval/1` read from the JSON snapshot a hook is
  # given: the struct, and its executor, stay with the session.
  defp approval(%{"policy" => %{"approval" => "never"}}), do: :never
  defp approval(%{"policy" => %{"approval" => "always"}}), do: :always
  defp approval(_descriptor), do: :policy

  defp edits_files?(descriptor) do
    effects = Map.get(descriptor, "effects", %{})
    resources = Map.get(effects, "resource_types", [])

    Map.get(effects, "class") == "write" and resources != [] and
      Enum.all?(resources, &(&1 in ["file", "directory"]))
  end

  # What a sandbox actually bounds: file edits and commands the environment
  # runs. An evaluation node or a remote service is outside it.
  defp confined?(descriptor) do
    effects = Map.get(descriptor, "effects", %{})
    resources = Map.get(effects, "resource_types", [])

    Map.get(effects, "class") in ["write", "arbitrary"] and resources != [] and
      Enum.all?(resources, &(&1 in ["file", "directory", "operating_system"])) and
      get_in(descriptor, ["origin", "type"]) != "mcp"
  end

  defp reason(%{name: "bash", arguments: %{"command" => command}}, _descriptor),
    do: "it runs `#{String.slice(Shell.normalize(command), 0, 80)}`"

  defp reason(%{name: name}, descriptor) do
    if edits_files?(descriptor),
      do: "#{name} changes files",
      else: "#{name} is not allowed by any rule"
  end

  # --- Suggestions ------------------------------------------------------------

  # Programs whose first argument is a subcommand worth keeping in a rule:
  # "always allow `git status`" is a different promise from "always allow git".
  @subcommand_programs ~w(git npm npx yarn pnpm bun mix cargo go docker kubectl make bundle rails
                          rake gh pip pip3 poetry uv dotnet swift gradle mvn terraform deno brew
                          composer php elixir iex rebar3 just task nx turbo)

  @doc """
  What "always allow" would mean for `call`: the rules and mode changes a
  host can offer on its approval card.
  """
  @spec suggestions(call :: map(), context :: map()) :: [map()]
  def suggestions(%{name: "bash", arguments: %{"command" => command}}, _context)
      when is_binary(command) do
    case Shell.split(command) do
      {:simple, [single]} ->
        prefix = command_prefix(single)

        [
          %{
            "label" => "Always allow `#{prefix} …` in this repository",
            "rule" => "Bash(#{prefix}:*)"
          }
        ]

      {_kind, _parts} ->
        normalized = Shell.normalize(command)

        [
          %{
            "label" => "Always allow this exact command in this repository",
            "rule" => "Bash(#{normalized})"
          }
        ]
    end
  end

  def suggestions(%{name: name, arguments: arguments} = call, context) do
    descriptor = Map.get(context, :tool_descriptor) || %{}

    cond do
      edits_files?(descriptor) ->
        [
          %{"label" => "Allow file edits for the rest of this session", "mode" => "accept_edits"},
          %{"label" => "Always allow file edits in this repository", "rule" => "Edit"}
        ]

      host = fetch_host(arguments) ->
        [%{"label" => "Always allow fetching from #{host}", "rule" => "WebFetch(domain:#{host})"}]

      true ->
        rule = hd(Claude.tool_aliases(name, descriptor) ++ [call.name])
        [%{"label" => "Always allow #{name} in this repository", "rule" => rule}]
    end
  end

  defp command_prefix(command) do
    case String.split(command) do
      [program, subcommand | _rest] when program in @subcommand_programs ->
        if String.starts_with?(subcommand, "-"), do: program, else: program <> " " <> subcommand

      [program | _rest] ->
        program
    end
  end

  defp fetch_host(%{"url" => url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _other -> nil
    end
  end

  defp fetch_host(_arguments), do: nil
end

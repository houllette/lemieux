defmodule Lemieux.Conversation.Command do
  @moduledoc """
  One slash command, as a module: what it is called, how its line is read,
  what performing it does, and what Tab offers after it.

  `Lemieux.Conversation` used to hold every command three times over — a
  `@commands` literal that `/help` printed and the TUI completed, a
  sixty-clause `typed/2` that parsed them, and a `command_action/1` table
  that named the action a host policy is shown — and the two front ends each
  kept a fourth copy in their `perform/2`. Four lists kept in step by hand is
  three too many: a command declared in one and missing from another was
  listed by help and then answered "is not a command" when somebody took the
  offer, and a test exists because it happened. Under this behaviour a
  command is one module that says all four things,
  `Lemieux.Conversation.Command.Builtin` lists the ones `lmx` ships, and a
  host adds its own by passing modules as `commands:` to
  `Lemieux.Conversation.new/1` — and through it to `Lemieux.TUI.start_link/1`.

  ## The callbacks

    * `c:spec/0` — the data `/help` and the completion menu read. `name`,
      `description` and `action` are required; `aliases`,
      `accepts_arguments?`, `hidden?`, `actions` and `subcommands` default as
      `spec!/1` documents. `action` is the effect a host's `command_policy`
      is shown when it decides whether to list the command at all —
      `:compact`, or `{:attach, nil}` for a command whose real effects carry
      an argument. It is the atom or tuple a policy already saw under the old
      table, so a policy written against that keeps working.
    * `c:parse/2` — the text after the command name (`""` for none) and the
      conversation, answering the effects to run. A bare list leaves the
      conversation as it was; `{conversation, effects}` changes it, which a
      command that opens a dialogue or notes what it is waiting on does;
      `{:error, line}` says the line and reprints the prompt. The parse is
      pure and decides everything about *meaning*, including whether the
      command may run mid-turn — see `wait/1`.
    * `c:perform/3` — the shared half of running the command: the session
      call. It has the shape of every per-effect function in
      `Lemieux.Conversation.Dispatch` — the host's own state, the
      `t:Lemieux.Conversation.Dispatch.t/0` the front end supplied, the
      effect — and returns the state. `Lemieux.Conversation.Dispatch.perform/3`
      finds the module by the effect's shape (`owner/2`) and calls this.
      A command a front end performs itself because it is about the screen
      — `/name`, `/theme`, `/resume` — returns the state unchanged here; the
      front end claimed the effect before the dispatcher saw it, and the
      clause is what says so.
    * `c:completions/2`, optional — what Tab offers after the command name,
      given what has been typed there so far and the conversation. Plain
      strings; the screen turns them into a menu. Only for a command whose
      argument the conversation can know — the ones that need the screen's
      catalog keep their menus in `Lemieux.TUI`.

  ## Actions and the policy

  A host's `command_policy` is shown parsed actions, never text, and every
  effect a `parse/2` produces that *is a command* — as opposed to a line to
  print or a prompt to send — has to be listed in `actions`, so the
  dispatcher can route it and the policy can be asked about it. `/model`
  lists `[:model_status, {:set_model, "SPEC"}]`: the tuple is an example of
  the shape, and `shape?/2` matches on the tag and the size. An effect no
  command lists is not policy-checked, which is what lets a host command
  answer `{:prompt, text}` the way a skill does.

  ## Shadowing

  Host modules go ahead of the built-ins, and a host module whose `name` or
  `aliases` collide with a built-in's replaces it: `/model` becomes whatever
  the host's module makes of it — in help, in completion and at the prompt.
  That is deliberate. A host that routes model selection through its own
  catalog wants to own the command, not sit beside it, and a built-in that
  kept answering under the same name would make the host's version the one
  that silently lost. Skills are merged after both, so a skill can never
  take a command's name.
  """

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command.Builtin
  alias Lemieux.Conversation.Dispatch

  @typedoc """
  The shape of an effect as `command_policy` sees it: the effect a parse
  produces, with `nil` where the person's argument would go — `{:deny, nil, nil}`
  stands for every `/deny ID reason`. A shape rather than a full effect so a
  policy can decide about a command before anyone has typed its argument.
  """
  @type action :: atom() | tuple()

  @typedoc """
  What `c:spec/0` returns, with every optional key filled in by `spec!/1`.

    * `:name`, `:aliases` — what is typed after the slash.
    * `:description` — the words `/help` puts beside it.
    * `:accepts_arguments?` — whether anything may follow the name. A command
      that does not is refused an argument before `c:parse/2` is asked.
    * `:action` — the effect a policy is shown for the bare command.
    * `:actions` — every command-shaped effect the parse can produce, `action`
      included. Defaults to `[action]`.
    * `:subcommands` — `{label, action}` pairs `/help` prints under the
      command when the policy allows each: `/tools enable NAME... | disable
      NAME...`. Defaults to none.
    * `:hidden?` — parsed but never listed or completed. `/habs` is one.
  """
  @type spec :: %{
          name: String.t(),
          aliases: [String.t()],
          description: String.t(),
          accepts_arguments?: boolean(),
          action: action(),
          actions: [action()],
          subcommands: [{String.t(), action()}],
          hidden?: boolean()
        }

  @typedoc "What `c:parse/2` answers. A bare list leaves the conversation as it was."
  @type parsed ::
          [Conversation.effect()]
          | {Conversation.t(), [Conversation.effect()]}
          | {:error, String.t()}

  @doc "The command's data. `name`, `description` and `action` are required."
  @callback spec() :: %{
              required(:name) => String.t(),
              required(:description) => String.t(),
              required(:action) => action(),
              optional(:aliases) => [String.t()],
              optional(:accepts_arguments?) => boolean(),
              optional(:actions) => [action()],
              optional(:subcommands) => [{String.t(), action()}],
              optional(:hidden?) => boolean()
            }

  @doc "Reads the text after the name, and answers the effects to run."
  @callback parse(arguments :: String.t(), conversation :: Conversation.t()) :: parsed()

  @doc "Performs one of the command's effects against the session, through the host."
  @callback perform(
              acc :: Dispatch.acc(),
              host :: Dispatch.t(),
              effect :: Conversation.effect()
            ) :: Dispatch.acc()

  @doc "What Tab offers after the name, given what is typed there so far."
  @callback completions(typed :: String.t(), conversation :: Conversation.t()) :: [String.t()]

  @optional_callbacks completions: 2

  @doc """
  The commands a conversation answers to: `extra` ahead of the built-ins,
  minus any built-in a host module shadows (see the module documentation).

  Every problem comes back at once: a module that is not a command, or a
  spec missing one of its required keys, names itself in the list.
  """
  @spec registry(extra :: [module()]) :: {:ok, [module()]} | {:error, [String.t()]}
  def registry(extra) when is_list(extra) do
    case extra |> Enum.flat_map(&problems/1) |> Enum.sort() do
      [] -> {:ok, merge(extra)}
      problems -> {:error, problems}
    end
  end

  @doc """
  `registry/1`, raising on a module it cannot use.

  For the host that passed the list in code, where a command that is not
  one is a programming error and a screen that quietly started without it
  would hide the mistake — the rule `Lemieux.TUI.Renderer.registry!/1`
  follows for the same reason.
  """
  @spec registry!(extra :: [module()]) :: [module()]
  def registry!(extra) when is_list(extra) do
    case registry(extra) do
      {:ok, commands} -> commands
      {:error, problems} -> raise ArgumentError, "commands: " <> Enum.join(problems, "; ")
    end
  end

  defp merge(extra) do
    taken = extra |> Enum.flat_map(&names/1) |> MapSet.new()

    extra ++ Enum.reject(Builtin.all(), &Enum.any?(names(&1), fn name -> name in taken end))
  end

  defp problems(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :spec, 0) and
         function_exported?(module, :parse, 2) and function_exported?(module, :perform, 3),
       do: spec_problems(module),
       else: ["#{inspect(module)} does not implement #{inspect(__MODULE__)}"]
  end

  defp problems(other), do: ["#{inspect(other)} is not a module"]

  defp spec_problems(module) do
    case module.spec() do
      %{name: name, description: description, action: _action}
      when is_binary(name) and name != "" and is_binary(description) ->
        []

      other ->
        [
          "#{inspect(module)}.spec/0 must return a map with :name, :description and :action; " <>
            "got #{inspect(other)}"
        ]
    end
  end

  @doc """
  The module's spec with every optional key filled in.

  Called wherever a spec is read, so no reader has to remember which keys a
  command may have left out.
  """
  @spec spec!(module :: module()) :: spec()
  def spec!(module) when is_atom(module) do
    spec = module.spec()
    action = Map.fetch!(spec, :action)

    %{
      name: Map.fetch!(spec, :name),
      aliases: Map.get(spec, :aliases, []),
      description: Map.fetch!(spec, :description),
      accepts_arguments?: Map.get(spec, :accepts_arguments?, false),
      action: action,
      # The policy action is always routable: a spec that listed `actions`
      # without it would parse to an effect the dispatcher could not own.
      actions: Enum.uniq([action | Map.get(spec, :actions, [])]),
      subcommands: Map.get(spec, :subcommands, []),
      hidden?: Map.get(spec, :hidden?, false)
    }
  end

  @doc "The name and every alias a command answers to."
  @spec names(module :: module()) :: [String.t()]
  def names(module) when is_atom(module) do
    spec = spec!(module)
    [spec.name | spec.aliases]
  end

  @doc "The command answering to `name` — its own name or an alias — or `nil`."
  @spec find(commands :: [module()], name :: String.t()) :: module() | nil
  def find(commands, name) when is_list(commands) and is_binary(name),
    do: Enum.find(commands, &(name in names(&1)))

  @doc """
  The command whose `actions` list `effect`'s shape, or `nil` for an effect
  that is not a command — a line to print, a prompt to send.
  """
  @spec owner(commands :: [module()], effect :: Conversation.effect()) :: module() | nil
  def owner(commands, effect) when is_list(commands),
    do:
      Enum.find(commands, &Enum.any?(spec!(&1).actions, fn action -> shape?(action, effect) end))

  @doc "Whether some command in `commands` owns `effect` — see `owner/2`."
  @spec action?(commands :: [module()], effect :: Conversation.effect()) :: boolean()
  def action?(commands, effect), do: not is_nil(owner(commands, effect))

  @doc """
  Whether `effect` has the shape `example` stands for.

  Atoms match themselves; tuples match on the tag and the size, so
  `{:set_model, "SPEC"}` in a spec stands for every `{:set_model, _}`.
  """
  @spec shape?(example :: Conversation.effect(), effect :: term()) :: boolean()
  def shape?(example, effect) when is_atom(example), do: example == effect

  def shape?(example, effect) when is_tuple(example) and is_tuple(effect),
    do: tuple_size(example) == tuple_size(effect) and elem(example, 0) == elem(effect, 0)

  def shape?(_example, _effect), do: false

  @doc """
  The specs `/help` lists and the menu completes: every command that is not
  hidden and whose `action` the policy allows, in registry order.
  """
  @spec listed(commands :: [module()], policy :: Conversation.command_policy()) :: [spec()]
  def listed(commands, policy) when is_list(commands) do
    commands
    |> Enum.map(&spec!/1)
    |> Enum.reject(& &1.hidden?)
    |> Enum.filter(&(Conversation.command_decision(policy, &1.action) == :allow))
  end

  @doc """
  The parse of a command that waits for the turn to end.

  The stock wording, for the commands that change what the session does:
  a model switch or a compaction under a running turn would race it.
  `message` is for the commands with something more specific to say.
  """
  @spec wait(message :: String.t()) :: [Conversation.effect()]
  def wait(message \\ "wait for it to finish first") when is_binary(message),
    do: [{:say, message}]

  @doc """
  The parse of a command that asks when given nothing and sets when given
  something — `/name`, `/color`, `/theme`, and the setting half of `/model`.

  A trailing space is somebody who has not finished typing, not a request
  to be called the empty string, so a blank argument asks too.
  """
  @spec argued(argument :: String.t(), status :: Conversation.effect(), action :: atom()) ::
          [Conversation.effect()]
  def argued(argument, status, action) when is_binary(argument) and is_atom(action) do
    case String.trim(argument) do
      "" -> [status]
      argument -> [{action, argument}]
    end
  end
end

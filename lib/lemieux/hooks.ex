defmodule Lemieux.Hooks do
  @moduledoc """
  Where a host attaches its policy.

  lemieux has no permission system in its core. Tools run with the
  permissions of whoever started the session, and nothing in the loop asks
  whether they should. That is a decision: every host means something
  different by "allowed" — a CLI asks a person, a server asks a database, a
  CI job asks nobody and denies everything outside its checkout — and a
  policy layer in the loop would be one they all have to defeat before
  implementing their own. `Lemieux.Extensions.Permissions` is the shipped
  policy for hosts that want one, and it is built on exactly this seam.

  What the library owes them instead is a seam that is impossible to get
  wrong, which is this one.

      Lemieux.start_session(
        hooks: [
          before_tool_call: fn call, context ->
            if call.name == "bash" and String.contains?(call.arguments["command"], "rm -rf"),
              do: {:deny, "this session may not delete things"},
              else: :allow
          end
        ],
        ...
      )

  ## The decisions

  `before_tool_call` receives the call and the tool context, and answers:

    * `:allow` — run it.
    * `{:deny, reason}` — do not run it. **The reason becomes the tool result
      the model reads.**
    * `{:rewrite, args}` — run it with these arguments instead.
    * `:pending` — somebody else decides. The call stops where it is, the
      session emits `{:tool_approval, call}`, and it stays stopped until
      `Lemieux.Session.resolve_tool/3` answers with one of the three above.
      A host that never answers is why there is a timeout, which denies the
      call rather than leaving a session that looks busy forever.
    * `{:pending, details}` — the same, with `details` (a map with atom keys)
      merged into the call the waiting party is shown. The shipped
      permission policy puts what it would remember under `:permission`, so
      an approval card can offer "always allow" without guessing.

  The context includes `:tool_descriptor`, the JSON descriptor-v1 snapshot
  for the effective tool. A host can therefore decide from stable identity,
  provenance, declared effects and resource scopes. Escape-hatch string
  inspection may add evidence, but is not a substitute for that contract.

  When a command hook explicitly allows a call — Claude Code's
  `permissionDecision: "allow"` — the hooks after it see
  `context.approved_by` naming that hook. An allow that is merely "no
  objection" does not set it: the difference is what lets a later permission
  policy skip its question for a call somebody already approved, and ask for
  one nobody did.

  `after_tool_call` receives the call, the result and the context. Its return
  value is ignored unless it is `{:feedback, text}`, which is appended to what
  the model reads — the same thing a command hook's `additionalContext` or
  post-tool block does. It is for observing and for telling the model
  something about what just happened; it cannot undo the call.

  The rest of the agent lifecycle uses the same list:

    * `session_start` and `session_end` observe the session lifecycle. A
      Claude Code `SessionStart` command is the exception that Claude Code
      makes it: what it prints is context for the model, given with the
      session's next prompt (see `session_start/3`).
    * `attention` observes transitions into human-waiting and back to working.
    * `user_prompt` may allow, deny or rewrite a submitted prompt.
    * `prepare_next_turn` may rewrite or deny the complete provider-neutral
      request immediately before its budget check and dispatch.
    * `stop` may allow the agent to stop or deny the stop with feedback that
      starts another model turn.
    * `error` observes a provider error.

  `stop` is deliberately not an observer. It must return `:allow` or
  `{:deny, feedback}` and is not wrapped by the best-effort observer rescue
  path. A host that only wants a notification should use `attention`, `error`
  or `session_end`; an invalid `stop` return is a failed decision hook.

  A hook value may also be a `Lemieux.Hooks.Command`, normally loaded from a
  versioned JSON file or a Claude Code settings file by
  `Lemieux.Hooks.Config`. Commands receive JSON on stdin. This is the
  script-hook shape used by other coding agents without making external
  processes the only extension seam an Elixir host gets.

  Several hooks of the same name may be given, and they run in order. A
  rewrite is threaded into the next hook, so policies compose; the first deny
  wins and the rest do not run.

  ## A denial the model can see

  The one rule that is not negotiable: **a denied call produces a tool result
  saying it was denied, and why.** The alternative — dropping the call, or
  reporting success — has been tried, and it produces an agent that carries on
  as though the file it was refused had been written. It will then build on
  that belief for the rest of the session, and everything after the denial is
  quietly wrong.

  A model told "denied: this session may not delete things" does something
  sensible instead. It is the same information; the difference is whether
  anyone is told.

  ## Where hooks run

  In the task that runs the tool, not in the session process, so a hook that
  needs to ask a database — or a person — does not stop the session answering
  anything else. A hook that raises kills that one call and becomes an error
  result the model reads; it does not take the session with it.

  One consequence worth knowing: a tool that crashes its own process never
  reaches `after_tool_call`, because there is no longer a process to run it
  in. The session still writes the `:tool_result` entry and still emits it, so
  a host that is *accounting* rather than observing should count entries, not
  hook calls.
  """

  require Logger

  alias Lemieux.Hooks.Claude
  alias Lemieux.Hooks.Command
  alias Lemieux.Hooks.SessionContext
  alias Lemieux.Provider
  alias Lemieux.Session
  alias Lemieux.Tool
  alias Lemieux.Tool.Result

  @typedoc "A lifecycle point a hook may observe or control."
  @type event ::
          :session_start
          | :attention
          | :user_prompt
          | :prepare_next_turn
          | :before_tool_call
          | :after_tool_call
          | :stop
          | :error
          | :session_end

  @typedoc "Hooks, as given on a session. Duplicate keys are allowed and run in order."
  @type t :: [{event(), function() | Command.t()}]

  @typedoc "What `before_tool_call` may answer."
  @type decision :: :allow | {:deny, String.t()} | {:rewrite, map()}

  @typedoc """
  A decision, or `:pending` — somebody else will decide — optionally with
  details for whoever that is.
  """
  @type answer :: decision() | :pending | {:pending, details :: map()}

  @typedoc "A session-level transition relevant to human attention."
  @type attention ::
          %{
            required(:state) => :waiting,
            required(:call_id) => String.t(),
            required(:kind) => atom()
          }
          | %{required(:state) => :working}

  # Events whose command hooks are matched against tool names, and therefore the
  # only ones `unmatched/2` can judge.
  @tool_events [:before_tool_call, :after_tool_call]

  @doc """
  Whether at least one hook is registered for `event`.

  `:user_prompt` also counts a Claude Code `SessionStart` command: what such
  a command prints reaches the model with the session's next prompt (see
  `session_start/3`), so that prompt has to pass through `user_prompt/3`
  even when no prompt hook was configured.
  """
  @spec registered?(hooks :: t(), event :: event()) :: boolean()
  def registered?(hooks, :user_prompt),
    do: Keyword.has_key?(hooks, :user_prompt) or claude_session_start?(hooks)

  def registered?(hooks, event), do: Keyword.has_key?(hooks, event)

  @doc """
  Runs the `before_tool_call` hooks, returning the arguments to run with.
  """
  @spec before_tool_call(
          hooks :: t(),
          call :: Provider.tool_call(),
          context :: Tool.context()
        ) :: {:ok, map()} | {:deny, String.t()}
  def before_tool_call(hooks, call, context) do
    hooks
    |> Keyword.get_values(:before_tool_call)
    |> Enum.reduce_while({:ok, Map.get(call, :arguments, %{}), context}, fn hook,
                                                                            {:ok, args, context} ->
      effective = %{call | arguments: args}

      hook
      |> before_tool(effective, context)
      |> decide(effective, context)
      |> case do
        :allow ->
          {:cont, {:ok, args, context}}

        {:rewrite, rewritten} when is_map(rewritten) ->
          {:cont, {:ok, rewritten, context}}

        {:approved, by, nil} ->
          {:cont, {:ok, args, Map.put(context, :approved_by, by)}}

        {:approved, by, rewritten} ->
          {:cont, {:ok, rewritten, Map.put(context, :approved_by, by)}}

        {:deny, reason} ->
          {:halt, {:deny, reason}}
      end
    end)
    |> case do
      {:ok, args, _context} -> {:ok, args}
      {:deny, reason} -> {:deny, reason}
    end
  end

  # `:pending` is answered by somebody else, later. The call waits here — in its own
  # task — until `Lemieux.Session.resolve_tool/3` supplies one of the three
  # ordinary decisions, or the session's timeout denies it. From this function's
  # point of view a pending hook is just a slow one.
  defp decide(:pending, call, context), do: park(call, %{}, context)

  defp decide({:pending, details}, call, context) when is_map(details),
    do: park(call, details, context)

  # A command hook that asked and also rewrote the input: the person is shown
  # the call as it would actually run, and approving it runs that.
  defp decide({:pending, details, rewritten}, call, context) when is_map(rewritten),
    do: decide_rewritten(park(%{call | arguments: rewritten}, details, context), rewritten)

  defp decide(decision, _call, _context), do: decision

  defp decide_rewritten(:allow, rewritten), do: {:rewrite, rewritten}
  defp decide_rewritten(decision, _rewritten), do: decision

  # The call itself keeps its keys; details only add to it. A policy cannot
  # change which call a person believes they are approving.
  defp park(call, details, context) do
    payload = details |> Map.drop([:id, :name, :arguments]) |> Map.merge(call)
    Session.park(context.session, call.id, :approval, payload)
  end

  defp before_tool(%Command{} = command, call, context) do
    if Command.matches_any?(command, tool_names(call.name, context)) do
      command
      |> Command.run(tool_input(command, :before_tool_call, call, context), context)
      |> tool_decision(command, context)
    else
      :allow
    end
  end

  defp before_tool(hook, call, context), do: hook.(call, context)

  @doc """
  Runs the `after_tool_call` hooks. Their return values are ignored.

  `after_tool_call_feedback/4` runs the same hooks and returns what they had
  to tell the model; call one or the other, not both.
  """
  @spec after_tool_call(
          hooks :: t(),
          call :: Provider.tool_call(),
          result :: {:ok, String.t()} | {:error, String.t()},
          context :: Tool.context()
        ) :: :ok
  def after_tool_call(hooks, call, result, context) do
    _feedback = after_tool_call_feedback(hooks, call, result, context)
    :ok
  end

  @doc """
  Runs the `after_tool_call` hooks and returns what they want the model told.

  A hook cannot undo a call that already ran, so a post-tool "block" is not a
  denial here. It is what Claude Code makes it: text appended to the result
  the model reads next — a formatter saying the file it just wrote does not
  compile, a policy saying the command it just ran should not have been.
  Sources, in hook order:

    * a function hook returning `{:feedback, text}`;
    * a command hook exiting `2` (its stderr, or its JSON `reason`);
    * a command hook's `"decision": "block"` with its `reason`;
    * a command hook's `hookSpecificOutput.additionalContext`.

  Everything else a post-tool hook returns is ignored, as it always was.
  """
  @spec after_tool_call_feedback(
          hooks :: t(),
          call :: Provider.tool_call(),
          result :: {:ok, String.t()} | {:error, String.t()},
          context :: Tool.context()
        ) :: [String.t()]
  def after_tool_call_feedback(hooks, call, result, context) do
    hooks
    |> Keyword.get_values(:after_tool_call)
    |> Enum.flat_map(&after_tool(&1, call, result, context))
  end

  @doc """
  Appends post-tool feedback to a collected tool result.

  The feedback follows the output under a marker, so the model can tell what
  the tool said from what a hook said about it. No feedback leaves the result
  untouched — byte for byte, since the result's size is accounted.
  """
  @spec append_feedback(
          result :: {:ok | :error, Result.t()},
          feedback :: [String.t()]
        ) :: {:ok | :error, Result.t()}
  def append_feedback(result, []), do: result

  def append_feedback({status, %Result{} = result}, feedback) when is_list(feedback) do
    notes = Enum.map_join(feedback, "\n", &("[hook] " <> &1))
    {status, %{result | model_text: result.model_text <> "\n\n" <> notes}}
  end

  defp after_tool(%Command{} = command, call, result, context) do
    if Command.matches_any?(command, tool_names(call.name, context)) do
      payload = tool_input(command, :after_tool_call, call, context)

      payload =
        payload
        |> Map.put("tool_result", tool_result(result))
        |> put_claude(command, "tool_response", tool_result(result))

      command |> Command.run(payload, context) |> post_tool_feedback(command)
    else
      []
    end
  end

  defp after_tool(hook, call, result, context) do
    case hook.(call, result, context) do
      {:feedback, text} when is_binary(text) and text != "" -> [text]
      _ignored -> []
    end
  end

  defp post_tool_feedback({:block, reason}, _command), do: [reason]

  defp post_tool_feedback({:warning, warning}, _command) do
    Logger.warning("lemieux: #{warning}")
    []
  end

  defp post_tool_feedback({:ok, output}, _command) do
    blocked =
      case output do
        %{"decision" => decision} when decision in ["block", "deny"] ->
          [output |> Map.get("reason") |> present("a post-tool hook objected")]

        _output ->
          []
      end

    blocked ++ additional_context(output)
  end

  defp additional_context(output) do
    case specific(output, "additionalContext") do
      text when is_binary(text) and text != "" -> [text]
      _none -> []
    end
  end

  @doc """
  Warnings for command hooks on tool events whose matcher names no tool in
  `tool_names`.

  A `"matcher": "Bash"` that matched nothing used to be indistinguishable
  from a policy that was never triggered, which is the one a person relies
  on. Only plain name lists are judged: a regular expression might match a
  tool that appears later, and an MCP name (`mcp__…`, `server__tool`) names a
  tool the session only learns about once the server connects.
  """
  @spec unmatched(hooks :: t(), tool_names :: [String.t()]) :: [String.t()]
  def unmatched(hooks, tool_names) when is_list(hooks) and is_list(tool_names) do
    known =
      tool_names
      |> Enum.flat_map(&[&1 | Claude.tool_aliases(&1)])
      |> MapSet.new(&String.downcase/1)

    hooks
    |> Enum.filter(fn {event, hook} -> event in @tool_events and is_struct(hook, Command) end)
    |> Enum.flat_map(fn {event, command} ->
      case Command.matcher_names(command) do
        :pattern -> []
        names -> unmatched_names(event, command, names, known)
      end
    end)
  end

  defp unmatched_names(event, command, names, known) do
    if Enum.any?(names, &(known?(&1, known) or remote?(&1))),
      do: [],
      else: [unmatched_warning(event, command, names)]
  end

  defp known?(name, known), do: MapSet.member?(known, String.downcase(name))
  defp remote?(name), do: String.contains?(name, "__")

  defp unmatched_warning(event, command, names) do
    who = if command.name, do: " (#{command.name})", else: ""

    "#{event_name(event)} hook#{who} matches #{Enum.join(names, "|")}, " <>
      "which names no tool this session has; it will never run"
  end

  @doc """
  Runs `session_start` hooks.

  Function hooks and Lemieux-dialect commands observe: their return values
  are ignored. A Claude Code (`:claude` dialect) command's output is
  context, as it is there — the plain text it prints and its
  `hookSpecificOutput.additionalContext` are given to the model ahead of
  the session's next prompt (`user_prompt/3`), at startup and again on a
  resume. Claude Code plugins such as an output style are nothing but a
  `SessionStart` hook; discarding what it printed made them load and
  silently do nothing.

  The output is held for the session named by `context.session` in its
  runtime (`context.supervisor`), which is what a session passes; a context
  without them runs the hooks and drops what they printed.

  A delegated subagent's session — one whose `context.root_session_id` names
  another session — runs with its parent's hooks, but not their Claude Code
  `SessionStart` commands: Claude Code fires `SubagentStart` for a subagent,
  never `SessionStart`. Running them there made every delegated task wait
  for them and then start with the parent's session-start text.

  Delegation is inferred from that id alone, with no separate flag, so a
  host that sets the `:root_session_id` session option on a top-level
  session to another session's id gets the same treatment: its Claude Code
  `SessionStart` commands are skipped without notice. The option exists for
  child sessions to inherit their parent's root; sessions meant to share a
  rate domain share a `:provider_limit_key` instead.
  """
  @spec session_start(hooks :: t(), source :: :startup | :resume, context :: map()) :: :ok
  def session_start(hooks, source, context) do
    texts =
      hooks
      |> Keyword.get_values(:session_start)
      |> Enum.flat_map(&start_session(&1, source, context))

    if session_context?(hooks, context), do: SessionContext.put(context, texts)
    :ok
  end

  defp start_session(%Command{dialect: :claude} = command, source, context) do
    if delegated?(context), do: [], else: run_session_start(command, source, context)
  end

  defp start_session(%Command{} = command, source, context),
    do: run_session_start(command, source, context)

  defp start_session(hook, source, context) do
    safely_observe(hook, %{source: source}, context, :session_start)
    []
  end

  defp run_session_start(command, source, context) do
    if Command.matches?(command, to_string(source)) do
      input =
        command
        |> base_input(:session_start, context)
        |> Map.merge(stringify(%{source: source}))

      outcome = Command.run(command, input, context)
      observe_command(outcome, command)
      session_context(outcome, command)
    else
      []
    end
  end

  defp session_context({:ok, output}, %Command{dialect: :claude}) do
    [Map.get(output, "plain_output"), specific(output, "additionalContext")]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.trim/1)
  end

  defp session_context(_outcome, _command), do: []

  defp session_context?(hooks, context),
    do: not delegated?(context) and claude_session_start?(hooks)

  defp claude_session_start?(hooks),
    do: Enum.any?(hooks, &match?({:session_start, %Command{dialect: :claude}}, &1))

  # A session started for a delegated task carries its root's id; a session
  # of its own is its own root.
  defp delegated?(%{root_session_id: root, session_id: id}) when is_binary(root),
    do: root != id

  defp delegated?(_context), do: false

  # Session-start output goes ahead of the first prompt it reaches, marked as
  # what it is, the way Claude Code puts it before the conversation; a prompt
  # hook's context goes after (`updated_prompt/2`). Waiting is bounded by the
  # session-start commands' own timeouts, so a hook that hangs costs the
  # first prompt its context, not the prompt.
  defp with_session_context(hooks, prompt, context) do
    if session_context?(hooks, context) do
      case SessionContext.take(context, session_start_budget(hooks)) do
        [] ->
          prompt

        texts ->
          "<session-start-hook-context>\n" <>
            Enum.join(texts, "\n\n") <> "\n</session-start-hook-context>\n\n" <> prompt
      end
    else
      prompt
    end
  end

  defp session_start_budget(hooks) do
    hooks
    |> Keyword.get_values(:session_start)
    |> Enum.map(fn
      %Command{timeout: timeout} -> timeout
      _function -> 0
    end)
    |> Enum.sum()
    |> Kernel.+(5_000)
  end

  @doc """
  Runs best-effort attention observers when a call parks or the last one releases.

  Return values are ignored and callback failures are rescued. The session
  invokes this from an observation task, so a slow notifier cannot block it.
  """
  @spec attention(hooks :: t(), attention :: attention(), context :: map()) :: :ok
  def attention(hooks, %{state: state} = attention, context) do
    observe(hooks, :attention, state, attention, context)
  end

  @doc """
  Runs `user_prompt` hooks, threading rewrites through later hooks.

  A prompt that gets through them also carries whatever Claude Code
  `SessionStart` commands printed and no earlier prompt has carried (see
  `session_start/3`), ahead of the prompt and marked as hook context. A
  denied prompt leaves it for the next one.
  """
  @spec user_prompt(hooks :: t(), prompt :: String.t(), context :: map()) ::
          {:ok, String.t()} | {:deny, String.t()}
  def user_prompt(hooks, prompt, context) do
    hooks
    |> Keyword.get_values(:user_prompt)
    |> Enum.reduce_while({:ok, prompt}, fn hook, {:ok, prompt} ->
      hook
      |> before_prompt(prompt, context)
      |> case do
        :allow -> {:cont, {:ok, prompt}}
        {:rewrite, rewritten} when is_binary(rewritten) -> {:cont, {:ok, rewritten}}
        {:deny, reason} when is_binary(reason) -> {:halt, {:deny, reason}}
      end
    end)
    |> case do
      {:ok, prompt} -> {:ok, with_session_context(hooks, prompt, context)}
      {:deny, reason} -> {:deny, reason}
    end
  end

  @doc """
  Runs host-native request preparation hooks in order.

  This is intentionally a request-to-request seam rather than a second agent
  loop. It lets an embedder add fresh context, change the system text or
  choose tools for one turn while provider translation and tool approval stay
  on their ordinary paths.

  The session supplies `context.retry`: `nil` for an ordinary request, or the
  same string-keyed retry note recorded on the following request (`"attempt"`,
  `"after_request_id"`, `"category"`, `"reason"`, `"delay_ms"`). Preparation runs
  again on a retry so current host policy still applies. Hosts counting logical
  iterations can skip that increment when `context.retry` is non-nil; actual
  provider attempts still consume the session's request and turn ceilings.
  A hook invocation is preparation, not proof that a request was dispatched.
  """
  @spec prepare_next_turn(hooks :: t(), request :: Lemieux.Request.t(), context :: map()) ::
          {:ok, Lemieux.Request.t()} | {:deny, String.t()}
  def prepare_next_turn(hooks, request, context) do
    hooks
    |> Keyword.get_values(:prepare_next_turn)
    |> Enum.reduce_while({:ok, request}, fn hook, {:ok, request} ->
      case hook.(request, context) do
        {:ok, %Lemieux.Request{} = rewritten} -> {:cont, {:ok, rewritten}}
        {:deny, reason} when is_binary(reason) -> {:halt, {:deny, reason}}
      end
    end)
  end

  defp before_prompt(%Command{} = command, prompt, context) do
    if Command.matches?(command, "userPromptSubmitted") do
      input = base_input(command, :user_prompt, context) |> Map.put("prompt", prompt)

      command
      |> Command.run(input, context)
      |> prompt_decision(prompt)
    else
      :allow
    end
  end

  defp before_prompt(hook, prompt, context), do: hook.(prompt, context)

  @doc """
  Runs `stop` hooks.

  A denial means "do not stop yet"; its reason is feedback for the next model
  turn. Rewrites have no meaning at this boundary.
  """
  @spec stop(hooks :: t(), reason :: atom(), context :: map()) ::
          :allow | {:deny, String.t()}
  def stop(hooks, reason, context) do
    hooks
    |> Keyword.get_values(:stop)
    |> Enum.reduce_while(:allow, fn hook, :allow ->
      decision = invoke_stop(hook, reason, context)

      case decision do
        :allow -> {:cont, :allow}
        {:deny, feedback} when is_binary(feedback) -> {:halt, {:deny, feedback}}
      end
    end)
  end

  defp invoke_stop(%Command{} = command, reason, context) do
    matcher = Atom.to_string(reason)

    if Command.matches?(command, matcher) do
      input =
        command
        |> base_input(:stop, context)
        |> Map.put("stop_reason", matcher)
        |> Map.put("stop_hook_active", Map.get(context, :stop_hook_active, false))

      command
      |> Command.run(input, context)
      |> stop_decision()
    else
      :allow
    end
  end

  defp invoke_stop(hook, reason, context), do: hook.(reason, context)

  @doc """
  Runs `error` hooks. Their return values are ignored.
  """
  @spec error(hooks :: t(), reason :: term(), context :: map()) :: :ok
  def error(hooks, reason, context) do
    observe(hooks, :error, "error", %{error: reason}, context)
  end

  @doc """
  Runs `session_end` hooks. Their return values are ignored.
  """
  @spec session_end(hooks :: t(), reason :: term(), context :: map()) :: :ok
  def session_end(hooks, reason, context) do
    observe(hooks, :session_end, describe(reason), %{reason: reason}, context)
  end

  defp observe(hooks, event, matcher, payload, context) do
    hooks
    |> Keyword.get_values(event)
    |> Enum.each(fn
      %Command{} = command ->
        if Command.matches?(command, to_string(matcher)) do
          input =
            command
            |> base_input(event, context)
            |> Map.merge(stringify(payload))
            |> observer_extras(command, event, payload)

          command |> Command.run(input, context) |> observe_command(command)
        end

      hook ->
        safely_observe(hook, payload, context, event)
    end)

    :ok
  end

  defp safely_observe(hook, payload, context, event) do
    hook.(observer_argument(event, payload), context)
  rescue
    error -> Logger.warning("lemieux: #{event} hook failed: #{Exception.message(error)}")
  end

  defp observer_argument(:session_start, %{source: source}), do: %{source: source}
  defp observer_argument(:attention, attention), do: attention
  defp observer_argument(:error, %{error: reason}), do: reason
  defp observer_argument(:session_end, %{reason: reason}), do: reason

  # Claude Code's Notification carries a sentence for a person, not a state.
  defp observer_extras(input, %Command{dialect: :claude}, :attention, payload),
    do: Map.put(input, "message", attention_message(payload))

  defp observer_extras(input, _command, _event, _payload), do: input

  defp attention_message(%{state: :waiting, kind: :question}),
    do: "The agent is waiting for your answer"

  defp attention_message(%{state: :waiting}), do: "The agent needs your permission to continue"
  defp attention_message(_payload), do: "The agent is working again"

  # --- Decisions from command output ------------------------------------------

  defp tool_decision({:block, reason}, _command, _context), do: {:deny, reason}

  defp tool_decision({:warning, warning}, _command, _context) do
    Logger.warning("lemieux: #{warning}")
    :allow
  end

  defp tool_decision({:ok, output}, command, context) do
    rewritten = updated_input(output, context)

    case permission(output) do
      {:deny, reason} -> {:deny, reason}
      {:ask, reason} -> ask(reason, command, rewritten)
      :approve -> {:approved, approver(command), rewritten}
      :none -> if rewritten, do: {:rewrite, rewritten}, else: :allow
    end
  end

  defp ask(reason, command, rewritten) do
    details = %{
      permission: %{
        "source" => "hook",
        "hook" => approver(command),
        "reason" => reason || "a hook asked for approval",
        "suggestions" => []
      }
    }

    if rewritten, do: {:pending, details, rewritten}, else: {:pending, details}
  end

  # Deny first, whatever else the output says: a script that both allows and
  # denies has at least one reason to deny, and the safe reading is that one.
  defp permission(%{"continue" => false} = output),
    do: {:deny, present(Map.get(output, "stopReason"), "a hook stopped the agent")}

  defp permission(%{"decision" => decision} = output) when decision in ["deny", "block"],
    do: {:deny, denial_reason(Map.get(output, "reason"))}

  defp permission(output) do
    permission = specific(output, "permissionDecision") || Map.get(output, "permissionDecision")

    permission_decision(permission, Map.get(output, "decision"), permission_reason(output))
  end

  # A field of Claude's `hookSpecificOutput`, when there is such an object. A
  # script that printed something else there gets no decision from it, not a
  # crashed call.
  defp specific(output, key) do
    case Map.get(output, "hookSpecificOutput") do
      %{} = specific -> Map.get(specific, key)
      _absent -> nil
    end
  end

  defp permission_decision("deny", _decision, reason), do: {:deny, denial_reason(reason)}
  defp permission_decision("ask", _decision, reason), do: {:ask, reason}
  defp permission_decision("allow", _decision, _reason), do: :approve

  defp permission_decision(_permission, decision, _reason) when decision in ["allow", "approve"],
    do: :approve

  defp permission_decision(_permission, _decision, _reason), do: :none

  defp permission_reason(output) do
    specific(output, "permissionDecisionReason") ||
      Map.get(output, "permissionDecisionReason") || Map.get(output, "reason")
  end

  defp updated_input(output, context) do
    case Map.get(output, "updated_input") ||
           specific(output, "updatedInput") do
      input when is_map(input) -> Claude.from_claude_input(input, schema_properties(context))
      _otherwise -> nil
    end
  end

  defp schema_properties(%{tool_descriptor: descriptor}) when is_map(descriptor) do
    case get_in(descriptor, ["interface", "input_schema", "properties"]) do
      properties when is_map(properties) -> properties
      _none -> %{}
    end
  end

  defp schema_properties(_context), do: %{}

  defp approver(%Command{name: name}) when is_binary(name), do: "hook " <> name
  defp approver(%Command{command: command}), do: "hook " <> String.slice(command, 0, 60)

  defp prompt_decision({:block, reason}, _prompt), do: {:deny, reason}

  defp prompt_decision({:warning, warning}, _prompt) do
    Logger.warning("lemieux: #{warning}")
    :allow
  end

  defp prompt_decision({:ok, output}, prompt) do
    case permission(output) do
      {:deny, reason} -> {:deny, reason}
      _other -> updated_prompt(output, prompt)
    end
  end

  defp updated_prompt(output, prompt) do
    context =
      [
        specific(output, "additionalContext"),
        Map.get(output, "plain_output")
      ]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    cond do
      is_binary(output["updated_prompt"]) -> {:rewrite, output["updated_prompt"]}
      context != [] -> {:rewrite, Enum.join([prompt | context], "\n\n")}
      true -> :allow
    end
  end

  defp stop_decision({:block, reason}), do: {:deny, reason}

  defp stop_decision({:warning, warning}) do
    Logger.warning("lemieux: #{warning}")
    :allow
  end

  # `continue: false` on a stop hook means "stop now", which is what stopping
  # already is; only an explicit block keeps the agent working.
  defp stop_decision({:ok, %{"decision" => decision} = output})
       when decision in ["deny", "block"],
       do: {:deny, denial_reason(Map.get(output, "reason"))}

  defp stop_decision({:ok, %{"permissionDecision" => "deny"} = output}),
    do: {:deny, denial_reason(Map.get(output, "permissionDecisionReason"))}

  defp stop_decision({:ok, _output}), do: :allow

  defp observe_command({:warning, warning}, _command),
    do: Logger.warning("lemieux: #{warning}")

  defp observe_command({:block, reason}, _command),
    do:
      Logger.warning(
        "lemieux: an observer hook tried to block an action that already happened: #{reason}"
      )

  defp observe_command(_outcome, _command), do: :ok

  # --- Input shapes -----------------------------------------------------------

  defp tool_names(name, context),
    do: [name | Claude.tool_aliases(name, Map.get(context, :tool_descriptor))]

  defp tool_input(%Command{dialect: :claude} = command, event, call, context) do
    descriptor = Map.get(context, :tool_descriptor)
    arguments = Map.get(call, :arguments, %{})

    command
    |> base_input(event, context)
    |> Map.merge(%{
      "tool_name" => Claude.tool_name(call.name, descriptor),
      "tool_input" => Claude.to_claude_input(call.name, arguments),
      "tool_use_id" => call.id
    })
  end

  defp tool_input(command, event, call, context) do
    command
    |> base_input(event, context)
    |> Map.merge(%{
      "tool_name" => call.name,
      "tool_input" => Map.get(call, :arguments, %{}),
      "tool_use_id" => call.id
    })
  end

  defp put_claude(input, %Command{dialect: :claude}, key, value), do: Map.put(input, key, value)
  defp put_claude(input, _command, _key, _value), do: input

  defp tool_result({:ok, output}), do: %{"output" => to_string(output), "error" => false}
  defp tool_result({:error, output}), do: %{"output" => to_string(output), "error" => true}

  defp base_input(command, event, context) do
    %{
      "session_id" => context.session_id,
      "cwd" => context.cwd,
      "hook_event_name" => input_event_name(command, event),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp input_event_name(%Command{dialect: :claude}, event),
    do: Claude.event_name(event) || event_name(event)

  defp input_event_name(_command, event), do: event_name(event)

  defp event_name(:session_start), do: "sessionStart"
  defp event_name(:attention), do: "attention"
  defp event_name(:user_prompt), do: "userPromptSubmitted"
  defp event_name(:before_tool_call), do: "preToolUse"
  defp event_name(:after_tool_call), do: "postToolUse"
  defp event_name(:stop), do: "agentStop"
  defp event_name(:error), do: "errorOccurred"
  defp event_name(:session_end), do: "sessionEnd"

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), json(value)} end)
  defp json(value) when is_atom(value), do: Atom.to_string(value)
  defp json(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json(value), do: inspect(value)

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp present(value, _fallback) when is_binary(value) and value != "", do: value
  defp present(_value, fallback), do: fallback

  defp denial_reason(reason) when is_binary(reason) and reason != "", do: reason
  defp denial_reason(nil), do: "hook denied the action"
  defp denial_reason(reason), do: inspect(reason)
end

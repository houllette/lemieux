defmodule Lemieux.CLI.Run do
  @moduledoc """
  `lmx run PROMPT` — one prompt, one answer, then exit.

  The headless half of the CLI: no terminal to type into, no turn after this
  one. It is the shape a script or a CI job uses, which is why the discipline
  about which stream gets what matters here more than anywhere else.

  ## What reaches stdout

  **Only the answer.** In the default `--output-format text`, stdout gets the
  final answer once the prompt has finished — not the narration the model
  wrote before each tool call. Streaming every text delta used to run those
  together ("I'll read the README.Here's…"), so `lmx run "…" > answer.txt`
  held a transcript fragment rather than an answer. Session ids, tool calls,
  retries, the context window and compaction, what `/undo` will not cover,
  the usage the prompt cost and errors go to stderr; stream-json carries the
  window and compaction notices as `notice` objects. Log lines go to
  neither (`Lemieux.CLI.Logs`): a connection failure used to
  put `req_llm`'s `[error]` line on stdout, in front of the answer or the
  JSON a script was about to parse.

  `--output-format json` writes one object when the prompt ends;
  `--output-format stream-json` writes one object per line as the work
  happens, ending with the same result object. Both name the model the
  session ran on, because a run that nobody gave `--model` picks one
  (`Lemieux.CLI.Models`), and both are documented in the CLI guide — they are
  what a script should parse instead of prose.

  On a terminal, text mode writes the answer and every stderr line through
  `Lemieux.CLI.Sanitize`: the answer is what a repository file or a fetched
  page may have talked the model into, and escape sequences in it would
  otherwise reach the terminal. Redirected, the answer is written exactly.

  ## Exit status

  The status says why the command stopped, as `Lemieux.CLI.Errors` defines
  it: 0 answered, 2 usage, 3 credentials, 4 a limit, 5 cancelled, 6 the
  provider failed after the session's retries, 1 anything else. A model
  specification that does not parse and a missing key are both found before
  a session exists: the first is status 2 and says how to write one, the
  second status 3 with the variable to set, and neither leaves a transcript
  behind.

  ## The prompt and the workspace

  The prompt is the arguments, joined. `-` among them stands for standard
  input, and with no arguments at all, piped input is the prompt. A terminal
  is never read, so a person who forgot the prompt is told rather than left
  at a waiting cursor.

  The repository's workspace — instructions, memory, skills and selected
  plugins, as `Lemieux.CLI.Runtime.discover_workspace/2` finds them — is
  loaded by default, so a script and the terminal UI answer from the same
  context. `--bare` opts out, and so does `--system`: a caller who wrote the
  whole system prompt meant all of it. An extension profile runs bare as
  well, because its prompt must reach every host unchanged. Personal
  instruction files are read
  only where lmx has a personal state directory, so `--config none` stays
  hermetic.

  `-c/--continue` resumes the newest session that ran in this directory, the
  way the terminal UI's flag does.

  Waiting goes through `Lemieux.Session.await/3`, which monitors the session:
  one that dies ends the command with an error status rather than hanging it.
  """

  alias Lemieux.CLI
  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Errors
  alias Lemieux.CLI.ExtensionExperience
  alias Lemieux.CLI.Models
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.Sanitize
  alias Lemieux.CLI.SessionIndex
  alias Lemieux.Conversation
  alias Lemieux.Conversation.Doctor
  alias Lemieux.Entry
  alias Lemieux.ID.Shorthand
  alias Lemieux.ModelSpec
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Session
  alias Lemieux.Usage

  @formats %{"text" => :text, "json" => :json, "stream-json" => :stream_json}

  # Bounds what one stream-json line carries of a tool's output, in
  # characters: a consumer that wants the whole thing reads the transcript,
  # and a line the size of a log file is one a line-oriented reader chokes on.
  @stream_output_chars 2_000

  # The tools whose changes `/undo` records only in a git repository; see
  # `undo_watch/2`.
  @command_tools ["bash", "elixir"]

  # The session's notices about its context window and compaction, which
  # stream-json carries as notices: it has no event of its own for them.
  @window_notices [:context_window_unknown, :context_window_small, :compaction_ineffective]

  @doc """
  Runs the command, returning `:ok` or `{:error, exit_status}`.

  `opts` may carry `:stdin` — the input as a binary, or a zero-arity function
  returning `{:ok, binary}` — and `:stdin_terminal?`, which say what standard
  input holds without reading the real one; `:terminal?`, which says whether
  standard output and standard error are terminals (`Lemieux.CLI.Sanitize`);
  and `:program`, how hints spell the command (`Lemieux.CLI.program/1`).
  Tests use all of them.
  """
  @spec main(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def main(argv, opts \\ []) do
    out = %{format: :text, opts: opts, model: nil}

    with {:ok, options} <- Options.parse(argv, command: :run),
         {:ok, format} <- output_format(options.given) do
      checked(options, %{out | format: format}, opts)
    else
      {:error, message} -> fail(out, :usage, message)
    end
  end

  defp output_format(given) do
    case Keyword.get(given, :output_format, "text") do
      name when is_map_key(@formats, name) ->
        {:ok, Map.fetch!(@formats, name)}

      name ->
        {:error,
         "invalid value for --output-format: #{inspect(name)} (expected text, json or stream-json)"}
    end
  end

  defp checked(options, out, opts) do
    with {:ok, opts} <- usage(Runtime.with_routes(options, opts)),
         {:ok, options, opts} <- usage(ExtensionExperience.prepare(options, opts)),
         :ok <- usage(one_of_continue_or_resume(options)),
         {:ok, prompt} <- usage(prompt(options.argv, opts)) do
      opts = Keyword.drop(opts, [:stdin, :stdin_terminal?])
      start(Runtime.project_mcp(options, opts), prompt, %{out | opts: opts}, opts)
    else
      {:error, category, message} -> fail(out, category, message)
    end
  end

  # Everything refused before a session exists is the command line's fault
  # — a flag, an argument, the configuration — which scripts see as status 2.
  defp usage({:error, message}) when is_binary(message), do: {:error, :usage, message}
  defp usage(result), do: result

  defp one_of_continue_or_resume(%Options{host: %{continue: true}, resume: resume})
       when is_binary(resume),
       do: {:error, "use --continue or --resume, not both"}

  defp one_of_continue_or_resume(_options), do: :ok

  defp prompt(argv, opts) do
    cond do
      "-" in argv ->
        with {:ok, input} <- read_stdin(opts), do: argv |> substitute(input) |> joined(opts)

      argv == [] and not terminal?(opts) ->
        with {:ok, input} <- read_stdin(opts), do: joined([input], opts)

      true ->
        joined(argv, opts)
    end
  end

  defp substitute(argv, input), do: Enum.map(argv, &stdin_part(&1, input))

  defp stdin_part("-", input), do: input
  defp stdin_part(part, _input), do: part

  defp joined(parts, opts) do
    prompt = Enum.join(parts, " ")

    if String.trim(prompt) == "",
      do:
        {:error,
         "run needs a prompt: #{CLI.program(opts)} run \"what should I do?\", or pipe one in"},
      else: {:ok, prompt}
  end

  defp read_stdin(opts) do
    case Keyword.get(opts, :stdin, &read_standard_input/0) do
      input when is_binary(input) -> {:ok, input}
      read when is_function(read, 0) -> read.()
    end
  end

  defp read_standard_input do
    case IO.read(:stdio, :eof) do
      data when is_binary(data) ->
        {:ok, data}

      :eof ->
        {:ok, ""}

      {:error, reason} ->
        {:error, "could not read the prompt from standard input: #{inspect(reason)}"}
    end
  end

  defp terminal?(opts) do
    case Keyword.fetch(opts, :stdin_terminal?) do
      {:ok, terminal?} -> terminal?
      :error -> standard_input_terminal?()
    end
  end

  # OTP reports whether standard input is a terminal among the io options. A
  # device that does not say — a test's captured io — counts as a terminal:
  # not reading is the safe answer, because a pipe nobody closes would be
  # waited on forever.
  defp standard_input_terminal? do
    case :io.getopts(:standard_io) do
      options when is_list(options) -> Keyword.get(options, :stdin, true)
      _unknown -> true
    end
  end

  defp start(options, prompt, out, opts) do
    store = Runtime.store(options, opts)
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)
    {options, continued} = continue(options, store, cwd)
    options = resolve_model(options, opts)
    out = %{out | model: reported_model(options)}
    context = error_context(options, opts)

    # No subscriber of its own: `Lemieux.Session.await/3` subscribes a relay
    # for the prompt, and a second subscription here would only fill this
    # process's mailbox with events nobody reads.
    with :ok <- model_spec(options, opts),
         :ok <- credential(options, opts),
         {:ok, opts} <- usage(Runtime.with_workspace(options, opts)),
         {:ok, prepared} <- prepared(Runtime.prepare(options, opts), context),
         {:ok, session} <- started(Runtime.start(prepared, subscriber: []), context) do
      out =
        Map.merge(out, %{
          model: prepared.model,
          context: context,
          checkpoints: prepared.checkpoints
        })

      notices(out, prepared.harness.notices ++ continued)
      converse(session, prompt, out)
    else
      {:error, category, message} ->
        refused(out, options, category, message)
    end
  end

  # Refused before any session existed, so before the harness's notices were
  # said. The configuration's warnings are said first all the same: they are
  # often the reason — "the model you last chose is not available (Ollama
  # did not answer), so this session starts on …" is why a key is missing —
  # and a credential refusal used to arrive alone, with the sentence that
  # explained it never printed.
  defp refused(out, options, category, message) do
    notices(out, Config.warnings(options.config))
    fail(out, category, message)
  end

  # What an error sentence may name. The model and the gateway let a failed
  # connection say where it was going; an Ixway route's failures describe
  # themselves (`Lemieux.Ixway.Error`), so it gets no model to guess with.
  defp error_context(options, opts) do
    [
      model: if(is_nil(options.ixway), do: options.model),
      base_url: options.base_url,
      resume: options.resume,
      program: CLI.program(opts)
    ]
  end

  # `--continue` resumes the newest session that ran in this directory, or
  # starts a new one saying so — the terminal UI's rule, so the two flags
  # cannot mean different things.
  defp continue(%Options{host: %{continue: true}, resume: nil} = options, store, cwd) do
    case SessionIndex.latest(store, cwd) do
      nil -> {options, ["no earlier session ran in #{cwd}; this is a new one"]}
      id -> {%{options | resume: id}, []}
    end
  end

  defp continue(options, _store, _cwd), do: {options, []}

  @doc """
  `options` with the model a new `lmx run` session starts on.

  A model nobody chose follows `Lemieux.CLI.Models`: the model the person
  last chose, then the first provider with a key, then a local Ollama model
  that can call tools. A host that supplied its own provider, gateway or
  endpoint keeps the model it asked for — picking another would point it
  somewhere it does not serve. Public so `lmx explain` reports this model
  rather than a guess at it (`Lemieux.CLI.Explain`).
  """
  @spec resolve_model(options :: Options.t(), opts :: keyword()) :: Options.t()
  def resolve_model(options, opts) do
    if host_route?(options, opts),
      do: options,
      else: options |> Models.resolve(opts) |> Models.local(opts)
  end

  defp host_route?(options, opts) do
    Keyword.has_key?(opts, :provider) or options.ixway != nil or options.host.route != nil or
      options.base_url != nil
  end

  # A model specification that `req_llm` cannot resolve — `gpt-4o` with no
  # provider, a provider it has never heard of — used to start a session,
  # write a transcript and then fail the first request with
  # "gpt-4o is not a model I can reach: invalid_format". Resolving it here
  # costs a catalog lookup and no request, and says how to write one. Only
  # where lmx resolves the provider itself and the session is new: a host
  # route serves its own model names, a resumed session runs on the model
  # its transcript recorded, `ixway:` names are the gateway's, and a
  # registered route's names are its own (`Lemieux.CLI.Runtime.route?/2`).
  defp model_spec(options, opts) do
    if host_route?(options, opts) or options.resume != nil or
         ModelSpec.provider(options.model) == "ixway" or Runtime.route?(opts, options.model) do
      :ok
    else
      case ReqLLM.model(options.model) do
        {:ok, _model} ->
          :ok

        {:error, reason} ->
          {:error, :usage,
           Errors.describe({:unknown_model, options.model, reason}, program: CLI.program(opts))}
      end
    end
  end

  # A new session whose model has no key stops here, with the variable to
  # set, instead of after the runtime started and the first request was
  # refused. A host route answers for its own credentials, and a resumed
  # session is checked by its first request, which knows the model the
  # transcript recorded.
  defp credential(options, opts) do
    provider = ModelSpec.provider(options.model)

    if host_route?(options, opts) or options.resume != nil or
         Models.credential(provider, options.config, opts) != :missing,
       do: :ok,
       else: {:error, :auth, Models.missing_key_message(options, CLI.program(opts))}
  end

  # A sentence from preparation is about the command as given — a flag, a
  # file, an extension — so it is a usage error; a typed reason is a
  # provider's or a credential's, and says which.
  defp prepared({:ok, prepared}, _context), do: {:ok, prepared}

  defp prepared({:error, message}, _context) when is_binary(message),
    do: {:error, :usage, message}

  defp prepared({:error, reason}, context),
    do:
      {:error, start_category(reason),
       "could not start a session: " <> Errors.describe(reason, context)}

  defp started({:ok, session}, _context), do: {:ok, session}

  defp started({:error, reason}, context),
    do: {:error, start_category(reason), Errors.describe(reason, context)}

  # A `--resume` reference that names no stored session, or names several,
  # is a wrong argument like any other, so status 2; it fell through to the
  # provider categories and exited 1, which `lmx run`'s contract keeps for
  # the unexpected.
  defp start_category(:not_found), do: :usage
  defp start_category({:ambiguous, _ids}), do: :usage
  defp start_category(reason), do: Errors.error_category(reason)

  # The model a failure before the session reports: for a resume, none until
  # the transcript is read — the model resolved so far is the placeholder a
  # new session would start on, which the JSON result named as if the
  # session had run on it.
  defp reported_model(%Options{resume: resume}) when is_binary(resume), do: nil
  defp reported_model(options), do: options.model

  # What the harness wants the person to know — a configuration file that was
  # named and could not be read — goes to stderr before the answer starts:
  # stdout is the answer. In stream-json it is an event like any other.
  defp notices(%{format: :stream_json} = out, notices),
    do: Enum.each(notices, &emit(out, %{"type" => "notice", "text" => &1}))

  defp notices(out, notices), do: Enum.each(notices, &say(out, &1))

  defp converse(session, prompt, out) do
    id = Session.id(session)
    info = info(session)
    announce(out, info, id)
    out = Map.put(out, :undo, undo_watch(out.checkpoints, info))

    result = Session.await(session, prompt, on_event: &progress(out, &1))
    outcome = outcome(id, result)
    deliver(out, outcome)

    # After the answer, so a `session_end` hook that prints lands on its own
    # line; before returning, because the halt that follows runs nobody's
    # `terminate/2`. See `Runtime.stop_session/1`.
    Runtime.stop_session(session)

    status(outcome.category)
  end

  # Both names, because this line has two readers. A script captures the id
  # and feeds it back to `--resume`; a person reading their terminal wants
  # the one they could still type tomorrow. The model, because nobody may
  # have chosen it, and its context window when it is known. An unknown one
  # is the session's to say: it sends `{:context_window_unknown, _}` before
  # the model's first request, with the size compaction assumes, and this
  # command hears it (`activity/1`). Said here as well, it came out twice,
  # the first line guessing at what the second one knew.
  defp announce(%{format: :stream_json} = out, info, id) do
    emit(out, %{
      "type" => "session",
      "session_id" => id,
      "name" => Shorthand.of(id),
      "model" => out.model,
      "context_window" => window(info)
    })
  end

  defp announce(out, info, id) do
    case window(info) do
      nil ->
        say(out, "session #{id} · #{Shorthand.of(id)} · #{out.model}")

      tokens ->
        say(
          out,
          "session #{id} · #{Shorthand.of(id)} · #{out.model} (#{thousands(tokens)} window)"
        )
    end
  end

  defp thousands(tokens) when tokens >= 10_000, do: "#{div(tokens, 1000)}k-token"
  defp thousands(tokens), do: "#{tokens}-token"

  # A session that stopped as it started is `Session.await/3`'s to report,
  # with a status; asking it here must not turn that into a crash first.
  defp info(session) do
    Session.info(session)
  catch
    :exit, _gone -> nil
  end

  defp window(%{context_window_known?: true, context: %{window: tokens}}) when is_integer(tokens),
    do: tokens

  defp window(_unknown), do: nil

  # What commands change is recorded for `/undo` only in a git repository
  # (`Lemieux.Conversation.Doctor.undo_coverage/1`), and `lmx run` records
  # checkpoints like the terminal UI does — `lmx --resume ID`, then `/undo`.
  # So the first command run where it is not says so, once, after its own
  # activity line: the check runs `git`, so it waits for a command, and a
  # run that only reads files hears nothing about it. The flag is shared
  # with the event callback, which `Lemieux.Session.await/3` calls with the
  # event alone.
  defp undo_watch(dir, %{cwd: cwd}) when is_binary(dir) and is_binary(cwd),
    do: %{cwd: cwd, said: :atomics.new(1, [])}

  defp undo_watch(_dir, _info), do: nil

  defp undo_scope(%{undo: %{cwd: cwd, said: said}} = out, {:tool_call, %{name: name}})
       when name in @command_tools do
    with :ok <- :atomics.compare_exchange(said, 1, 0, 1),
         notice when is_binary(notice) <- Doctor.undo_notice(cwd),
         do: say(out, notice)

    :ok
  end

  defp undo_scope(_out, _event), do: :ok

  # What happens while the prompt runs. In text and json the answer waits for
  # the end, so a person watching a five-minute run is told on stderr that
  # something is happening — which tool, which retry, a compaction — and the
  # model's narration between tool calls goes nowhere: it is in the
  # transcript, and on a terminal it would repeat the answer that follows.
  defp progress(%{format: :stream_json} = out, event) do
    case stream_event(event, out) do
      nil -> :ok
      line -> emit(out, line)
    end
  end

  defp progress(out, event) do
    case activity(event) do
      nil -> :ok
      line -> say(out, line)
    end

    undo_scope(out, event)
  end

  @doc """
  The line text and json mode write on standard error for a session event,
  without the `lmx: ` in front, or `nil` for an event they say nothing
  about.

  Public because compaction and the window notices, which several of these
  report, cannot be produced by one `lmx run` against a scripted provider
  without staging a whole earlier conversation; the event shapes are
  `Lemieux.Session`'s.
  """
  @spec activity(event :: term()) :: String.t() | nil
  def activity({:tool_call, call}), do: "#{call.name} #{summarise(call.arguments)}"
  def activity({:provider_retry, %{} = retry}), do: retrying(retry)

  def activity({:waiting_for_mcp, %{servers: servers}}),
    do: "waiting for MCP servers: #{Enum.join(servers, ", ")}"

  def activity({:context_window_unknown, %{model: _model} = unknown}), do: window_unknown(unknown)

  # The terminal UI's sentences (`Lemieux.Conversation`): a 4,096-token
  # Ollama window drops the task without an error, and a script running one
  # heard nothing about it.
  def activity({:context_window_small, %{model: _, window: _, overhead: _} = small}),
    do: Conversation.small_window(small)

  def activity({:compaction_ineffective, %{input_tokens: _, threshold: _, retry_in: _} = info}),
    do: Conversation.ineffective_compaction(info)

  def activity({:compacted, %{} = compacted}), do: compacted(compacted)

  def activity({:compaction_failed, reason}),
    do: "compaction failed, so nothing was cut: #{Errors.describe(reason)}"

  def activity({:context_recovery, %{}}),
    do: "the request did not fit the context window; compacting once and sending it again"

  def activity(_event), do: nil

  defp retrying(retry) do
    kept = if retry[:after_output], do: "; the partial answer is kept", else: ""

    "provider request failed (#{ProviderError.message(retry[:reason])}); " <>
      "retrying in #{retry[:delay_ms]}ms (#{retry[:attempt]}/#{retry[:max]})#{kept}"
  end

  # Said before the model's first request, and again if the model changes,
  # because it explains a long run that compacts late or not at all. A local
  # Ollama model's window is the server's own setting, which the session
  # learns once the model is loaded: `--context-window` only tells the
  # planner a number, and the window Ollama serves still decides what the
  # model sees, so for one the advice is that setting and where to read it.
  defp window_unknown(%{model: model, fallback: fallback}) when is_integer(fallback),
    do:
      "nothing knows #{model}'s context window; compaction assumes #{fallback} tokens" <>
        window_advice(model)

  defp window_unknown(%{model: model, fallback: nil}),
    do:
      "nothing knows #{model}'s context window, so the conversation is never compacted " <>
        "on its own" <> window_advice(model)

  defp window_unknown(%{model: model}),
    do: "nothing knows #{model}'s context window" <> window_advice(model)

  defp window_advice("ollama:" <> _tag),
    do:
      " until Ollama reports the window it serves (set OLLAMA_CONTEXT_LENGTH to 32768 or " <>
        "more for the Ollama server; `ollama ps` shows the window once the model is loaded)"

  defp window_advice(_model), do: " (--context-window N says how many tokens it holds)"

  defp compacted(%{tokens: %{before: before, after: remaining}}),
    do: "compacted the conversation: about #{before} → #{remaining} tokens"

  defp compacted(_compacted), do: "compacted the conversation"

  # One line, whatever the model passed. The first string argument is almost
  # always the interesting one — a path, a command — and the rest is noise on
  # a terminal.
  defp summarise(arguments) when is_map(arguments) and map_size(arguments) > 0 do
    arguments
    |> Map.values()
    |> Enum.find(&is_binary/1)
    |> case do
      nil -> ""
      value -> value |> String.split("\n", parts: 2) |> List.first() |> String.slice(0, 90)
    end
  end

  defp summarise(_arguments), do: ""

  # The stream-json vocabulary: a small, documented projection of the
  # session's events, never the internal terms themselves, which change.
  defp stream_event({:text_delta, %{text: text}}, _out), do: %{"type" => "text", "text" => text}

  defp stream_event({:tool_call, call}, _out) do
    %{"type" => "tool_call", "id" => call.id, "name" => call.name, "arguments" => call.arguments}
  end

  defp stream_event({:entry, %Entry{type: :tool_result, payload: payload}}, _out) do
    output = payload |> Map.get("output") |> to_text()

    %{
      "type" => "tool_result",
      "id" => Map.get(payload, "call_id"),
      "name" => Map.get(payload, "name"),
      "error" => Map.get(payload, "error") == true,
      "output" => String.slice(output, 0, @stream_output_chars),
      "output_bytes" => byte_size(output)
    }
  end

  defp stream_event({:provider_retry, %{} = retry}, _out) do
    %{
      "type" => "retry",
      "attempt" => retry[:attempt],
      "max" => retry[:max],
      "delay_ms" => retry[:delay_ms],
      "after_output" => retry[:after_output] == true,
      "message" => ProviderError.message(retry[:reason])
    }
  end

  defp stream_event({:waiting_for_mcp, %{servers: servers} = waiting}, _out),
    do: %{"type" => "waiting_for_mcp", "servers" => servers, "timeout_ms" => waiting[:timeout_ms]}

  defp stream_event({:error, reason}, out) do
    %{
      "type" => "error",
      "category" => Atom.to_string(Errors.error_category(reason)),
      "message" => Errors.describe(reason, Map.get(out, :context, []))
    }
  end

  # What text mode says about the context window and compaction, as the
  # notices a configuration problem already is here: a script running a
  # local model whose window cannot hold the task has more reason to hear it
  # than a person at a terminal.
  defp stream_event({kind, _detail} = event, _out) when kind in @window_notices do
    case activity(event) do
      nil -> nil
      text -> %{"type" => "notice", "text" => text}
    end
  end

  defp stream_event(_event, _out), do: nil

  defp to_text(text) when is_binary(text), do: text
  defp to_text(nil), do: ""
  defp to_text(other), do: inspect(other)

  defp outcome(id, {:ok, result}) do
    category = Errors.category(result.stop_reason, result.error)

    %{
      session_id: id,
      text: answer(result, category),
      stop_reason: result.stop_reason,
      error: result.error,
      usage: result.usage,
      category: category
    }
  end

  defp outcome(id, {:error, reason}),
    do: %{session_id: id, text: "", stop_reason: nil, error: reason, usage: nil, category: :other}

  # The answer the prompt ended on. A run that failed before finishing one
  # keeps the last text the model produced — an interrupted stream's partial
  # answer — because a script can still use what was said: the status, not
  # silence, says it failed.
  defp answer(%{text: text}, _category) when text != "", do: text
  defp answer(_result, :ok), do: ""

  defp answer(%{entries: entries}, _category) do
    entries
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %Entry{type: :assistant, payload: %{"content" => content}} when is_list(content) ->
        content |> content_text() |> non_empty()

      _entry ->
        nil
    end)
  end

  defp content_text(content) do
    content
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join(&Map.get(&1, "text", ""))
  end

  defp non_empty(""), do: nil
  defp non_empty(text), do: text

  defp deliver(%{format: :text} = out, outcome) do
    if outcome.text != "",
      do: IO.puts(Sanitize.for_device(outcome.text, :stdio, out.opts[:terminal?]))

    report_usage(out, outcome.usage)
    complain(out, outcome)
  end

  defp deliver(%{format: :json} = out, outcome) do
    emit(out, result_object(out, outcome))
    complain(out, outcome)
  end

  defp deliver(%{format: :stream_json} = out, outcome),
    do: emit(out, result_object(out, outcome))

  # What the prompt cost, after the answer, on stderr: the json formats
  # carry it in the result object, and text mode had no way to learn it at
  # all. A prompt that made no request has nothing to say.
  defp report_usage(out, %{"input_tokens" => input, "output_tokens" => output} = usage)
       when input + output > 0 do
    cached = Map.get(usage, "cache_read_tokens", 0)
    cached = if cached > 0, do: " (#{cached} cached)", else: ""

    cost =
      case Usage.cost_usd(usage) do
        nil -> "cost unknown"
        dollars -> "$" <> :erlang.float_to_binary(dollars / 1, decimals: 4)
      end

    say(out, "usage: #{input} tokens in#{cached} · #{output} out · #{cost}")
  end

  defp report_usage(_out, _usage), do: :ok

  defp complain(_out, %{category: :ok}), do: :ok
  defp complain(out, outcome), do: say(out, message(out, outcome))

  defp message(_out, %{error: {:session_down, reason}}),
    do: "the session stopped: #{inspect(reason)}"

  # The output cap ended the answer. The partial answer is on stdout and the
  # status still says it failed, so a script cannot take half an answer for
  # a whole one; the sentence says why, where `:length` said nothing, and how
  # to have the model carry on.
  defp message(out, %{error: nil, stop_reason: :length, session_id: id}) when is_binary(id),
    do:
      "the answer did not complete: it was cut off at the model's output limit; " <>
        "#{CLI.program(out.opts)} run --resume #{id} continue picks up where it stopped"

  defp message(_out, %{error: nil, stop_reason: reason}),
    do: "session did not complete: #{inspect(reason)}"

  defp message(out, %{error: error}), do: Errors.describe(error, Map.get(out, :context, []))

  defp result_object(out, outcome) do
    %{
      "type" => "result",
      "session_id" => outcome.session_id,
      "model" => out.model,
      "text" => outcome.text,
      "stop_reason" => stop_reason_text(outcome.stop_reason),
      "usage" => outcome.usage,
      "error" => error_object(out, outcome),
      "exit_status" => Errors.exit_status(outcome.category)
    }
  end

  defp error_object(_out, %{category: :ok}), do: nil

  defp error_object(out, outcome),
    do: %{"category" => Atom.to_string(outcome.category), "message" => message(out, outcome)}

  defp stop_reason_text(nil), do: nil
  defp stop_reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp stop_reason_text({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp stop_reason_text(reason), do: inspect(reason)

  defp status(:ok), do: :ok
  defp status(category), do: {:error, Errors.exit_status(category)}

  # JSON keeps the text exactly; `Sanitize.json/1` only escapes the C1
  # controls its encoder leaves raw, which a decoder reads back unchanged.
  defp emit(_out, object), do: IO.puts(object |> JSON.encode!() |> Sanitize.json())

  # One line on stderr, through the sanitiser when stderr is a terminal: the
  # lines name tools, arguments and errors the model's output chose.
  defp say(out, line),
    do: IO.puts(:stderr, Sanitize.for_device("lmx: " <> line, :stderr, out.opts[:terminal?]))

  # Refused before any answer existed: the sentence on stderr and, for the
  # JSON formats, the same result object a finished run ends with — so a
  # script reads one shape whichever way the command stopped.
  defp fail(out, category, message) do
    say(out, message)

    if out.format in [:json, :stream_json] do
      emit(out, %{
        "type" => "result",
        "session_id" => nil,
        "model" => out.model,
        "text" => "",
        "stop_reason" => nil,
        "usage" => nil,
        "error" => %{"category" => Atom.to_string(category), "message" => message},
        "exit_status" => Errors.exit_status(category)
      })
    end

    {:error, Errors.exit_status(category)}
  end
end

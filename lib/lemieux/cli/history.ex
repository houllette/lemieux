defmodule Lemieux.CLI.History do
  @moduledoc """
  `lmx log`, `lmx request` and `lmx fork` — commands that read a transcript.

  Neither starts an agent or talks to a provider, which is the point worth
  noticing: replaying a conversation and branching one are reads over entries
  lemieux wrote, so they cost nothing, work offline, and work on a transcript
  copied from another machine. A harness that wrapped somebody else's CLI
  could offer neither, because the conversation would live in that program's
  private store.

  `fork` prints the new id and nothing else on stdout, so it composes:

      lmx --resume "$(lmx fork SESSION --at ENTRY)"

  `log` prints what the model and its tools said, which is whatever a
  repository file or a fetched page talked the model into; on a terminal it
  goes through `Lemieux.CLI.Sanitize`, so an escape sequence in a transcript
  is printed as nothing rather than obeyed. `--jsonl` and `request` print
  JSON, whose text is exact.
  """

  alias Lemieux.CLI
  alias Lemieux.CLI.Errors
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.Sanitize
  alias Lemieux.Entry
  alias Lemieux.ID.Shorthand
  alias Lemieux.Store
  alias Lemieux.Transcript

  @doc """
  `lmx log SESSION` — prints a stored transcript.

  `opts` may carry `:terminal?`, whether standard output is a terminal
  (`Lemieux.CLI.Sanitize.terminal?/2` asks when it is absent).
  """
  @spec log(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def log(argv, opts \\ []) do
    with {:ok, options} <- parse(argv, :log),
         {:ok, id} <- session_id(options.argv, "log", opts),
         {:ok, entries} <- read(options, id, opts) do
      print(entries, options.jsonl, opts)
    end
  end

  defp print(entries, true = _jsonl, _opts),
    do: Enum.each(entries, &IO.puts(&1 |> Entry.encode!() |> Sanitize.json()))

  defp print(entries, _jsonl, opts) do
    terminal? = Sanitize.terminal?(:stdio, opts[:terminal?])

    entries
    |> offered_tools()
    |> Enum.each(fn {entry, tools} -> render(entry, %{terminal?: terminal?, tools: tools}) end)
  end

  @doc "`lmx request SESSION REQUEST_ID` — prints one canonical request snapshot."
  @spec request(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def request(argv, opts \\ []) do
    with {:ok, options} <- parse(argv, :request),
         {:ok, {id, request_id}} <- request_ids(options.argv, opts),
         {:ok, entries} <- read(options, id, opts),
         {:ok, entry} <- find_request(entries, request_id) do
      IO.puts(entry |> Entry.encode!() |> Sanitize.json())
    end
  end

  @doc """
  `lmx fork SESSION [--at ENTRY]` — copies a transcript and prints the new id.
  """
  @spec fork(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def fork(argv, opts \\ []) do
    with {:ok, options} <- parse(argv, :fork),
         {:ok, id} <- session_id(options.argv, "fork", opts),
         {:ok, forked} <- do_fork(options, id, opts) do
      IO.puts(forked)
    end
  end

  # Each of these takes whichever of a session's two names the caller had —
  # the id, or the shorthand the picker showed them. Resolving here rather
  # than in `session_id/3` keeps the store, which the resolution needs, out of
  # argument parsing.
  defp read(options, reference, opts) do
    store = store(options, opts)

    with {:ok, id} <- Shorthand.resolve(store, reference),
         {:ok, entries} <- Store.read(store, id) do
      {:ok, entries}
    else
      {:error, reason} -> fail(describe(reason, reference, opts))
    end
  end

  defp do_fork(options, reference, opts) do
    store = store(options, opts)

    with {:ok, selector} <- fork_selector(options),
         {:ok, id} <- Shorthand.resolve(store, reference),
         {:ok, forked} <- Transcript.fork(store, id, selector, unsafe: options.unsafe) do
      {:ok, forked}
    else
      {:error, status} when is_integer(status) -> {:error, status}
      {:error, reason} -> fail(describe(reason, reference, opts))
    end
  end

  # A flag that does not apply, or a value of the wrong type, is a sentence
  # and a status, like every other mistake here; returned bare it reached
  # `System.halt/1` as a string.
  defp parse(argv, command) do
    case Options.parse(argv, command: command) do
      {:ok, options} -> {:ok, options}
      {:error, message} -> fail(message)
    end
  end

  # The same store the agent commands build, so `lmx log` reads what `lmx run`
  # just wrote without being told where.
  defp store(options, opts), do: Runtime.store(options, opts)

  defp session_id([], command, opts),
    do: fail("#{command} needs a session id: #{CLI.program(opts)} #{command} SESSION")

  defp session_id([id | _rest], _command, _opts), do: {:ok, id}

  defp request_ids([id, request_id], _opts), do: {:ok, {id, request_id}}

  defp request_ids(_argv, opts) do
    program = CLI.program(opts)

    fail(
      "request needs a session and a request id: #{program} request SESSION ID " <>
        "(#{program} log SESSION --jsonl lists the request entries)"
    )
  end

  defp find_request(entries, request_id) do
    case Transcript.request(entries, request_id) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> fail("no request #{request_id}")
    end
  end

  defp fork_selector(%{at: at}), do: fork_point(at)

  defp fork_point(%{seq: seq}) when is_integer(seq) and seq >= 0, do: {:ok, {:seq, seq}}
  defp fork_point(%{seq: seq}) when is_integer(seq), do: fail("--at-seq must be non-negative")
  defp fork_point(%{turn: turn}) when is_integer(turn) and turn > 0, do: {:ok, {:turn, turn}}
  defp fork_point(%{turn: turn}) when is_integer(turn), do: fail("--at-turn must be positive")
  defp fork_point(%{entry: entry}), do: {:ok, entry}

  defp render(%Entry{type: :user, payload: %{"text" => text}}, log), do: say(log, "you", text)

  defp render(%Entry{type: :assistant, payload: payload}, log) do
    payload
    |> Map.get("content", [])
    |> Enum.each(fn
      %{"type" => "text", "text" => text} -> say(log, "agent", text)
      %{"type" => "thinking"} -> :ok
      _other -> :ok
    end)

    payload
    |> Map.get("tool_calls", [])
    |> Enum.each(&say(log, "  ·", "#{&1["name"]} #{arguments(&1)}"))
  end

  defp render(%Entry{type: :tool_result, payload: payload}, log),
    do: say(log, "  →", truncate(payload["output"]))

  defp render(%Entry{type: :error, payload: payload}, log),
    do: say(log, error_label(payload), error_text(payload))

  defp render(%Entry{type: :cancelled}, log), do: say(log, "", "— cancelled —")

  defp render(%Entry{type: :session, payload: payload}, log),
    do: say(log, "", "— #{payload["model"]}, tools: #{tool_names(log.tools, payload)} —")

  defp render(%Entry{type: :fork, payload: payload}, log),
    do: say(log, "", "— forked from #{payload["from"]} at #{payload["at"]} —")

  defp render(%Entry{}, _log), do: :ok

  # An error entry holds the provider's own wording and its category
  # (`Lemieux.Turn`). Printed as an inspected map it was a line of Elixir,
  # and for a missing key that wording is `req_llm`'s, which ends "(.env via
  # dotenvy)": a `.env` file the installed `lmx` never reads.
  defp error_label(%{"category" => category}) when category not in [nil, "other"],
    do: "error (#{String.replace(category, "_", " ")})"

  defp error_label(_payload), do: "error"

  defp error_text(%{"reason" => reason}) when is_binary(reason) do
    case Regex.run(~r/\b([A-Z][A-Z0-9_]*_(?:API_KEY|KEY|TOKEN)) env var\b/, reason) do
      [_match, variable] -> "no API key was found: set #{variable}"
      nil -> reason |> String.replace(" (.env via dotenvy)", "") |> String.trim()
    end
  end

  defp error_text(payload), do: inspect(payload)

  defp say(_log, _label, nil), do: :ok
  defp say(log, "", text), do: IO.puts(printable(log, "\n#{text}"))
  defp say(log, label, text), do: IO.puts(printable(log, "\n#{label}: #{text}"))

  defp printable(%{terminal?: terminal?}, text), do: Sanitize.for_device(text, :stdio, terminal?)

  # Each entry with the tools its header names: for a session entry, the
  # tools the model was offered under it — the first request snapshot after
  # it and before the next session entry, which a `/model` switch or a
  # resume with other tools appends — and `nil` for everything else, or for
  # a header no request followed. The session entry records module names,
  # what restores, and extensions add tools it never lists, so its header
  # named the todo tool "tool" (`Lemieux.Extensions.Planning.Tool`) and left
  # out five of the nine tools the model actually had. Walked from the end,
  # so the request after each header is the one most recently passed.
  defp offered_tools(entries) do
    {tagged, _next} =
      entries
      |> Enum.reverse()
      |> Enum.map_reduce(nil, fn
        %Entry{type: :request, payload: %{"tools" => tools}} = entry, _next
        when is_list(tools) ->
          {{entry, nil}, for(%{"name" => name} when is_binary(name) <- tools, do: name)}

        %Entry{type: :session} = entry, next ->
          {{entry, next}, nil}

        entry, next ->
          {{entry, nil}, next}
      end)

    Enum.reverse(tagged)
  end

  defp tool_names([], _payload), do: "none"
  defp tool_names(offered, _payload) when is_list(offered), do: Enum.join(offered, ", ")

  # Without a request to read, the module names are all there is: the short
  # name of each is what a person reading a log can use.
  defp tool_names(nil, %{"tools" => []}), do: "none"

  defp tool_names(nil, %{"tools" => tools}) when is_list(tools) do
    tools |> Enum.map_join(", ", &(&1 |> String.split(".") |> List.last() |> String.downcase()))
  end

  defp tool_names(nil, _payload), do: "unknown"

  defp arguments(call) do
    call
    |> Map.get("arguments", %{})
    |> Map.values()
    |> Enum.find(&is_binary/1)
    |> case do
      nil -> ""
      value -> value |> String.split("\n", parts: 2) |> List.first() |> String.slice(0, 90)
    end
  end

  # A transcript is read to be understood, not to be replayed verbatim: a
  # tool that returned a megabyte of build output would bury everything said
  # around it.
  defp truncate(nil), do: nil

  defp truncate(output) do
    case String.split(output, "\n", parts: 2) do
      [line] -> String.slice(line, 0, 200)
      [line | _rest] -> String.slice(line, 0, 200) <> " …"
    end
  end

  defp describe(:not_found, reference, opts),
    do: Errors.describe(:not_found, resume: reference, program: CLI.program(opts))

  defp describe({:ambiguous, ids}, reference, _opts),
    do: "#{reference} names #{length(ids)} sessions: #{Enum.join(ids, ", ")}"

  defp describe({:unknown_entry, at}, id, _opts), do: "no entry #{at} in session #{id}"
  defp describe({:unknown_seq, at}, id, _opts), do: "no sequence #{at} in session #{id}"
  defp describe({:unknown_turn, at}, id, _opts), do: "no completed turn #{at} in session #{id}"

  defp describe({:unsafe_fork, at}, _id, _opts),
    do: "entry #{at} is inside an unfinished turn (pass --unsafe to override)"

  defp describe({:unreadable, _id, _why} = reason, _reference, _opts),
    do: Errors.describe(reason)

  defp describe(reason, id, _opts), do: "could not read session #{id}: #{inspect(reason)}"

  defp fail(message) do
    IO.puts(:stderr, "lmx: #{message}")

    {:error, 1}
  end
end

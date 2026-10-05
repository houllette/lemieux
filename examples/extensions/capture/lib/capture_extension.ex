defmodule CaptureExtension do
  @moduledoc """
  Turns ordinary `lmx` sessions into draft evaluation cases.

  The self-improvement corpus grows one reviewed case at a time, and cases
  arrive through feedback that somebody remembered to write. This extension
  writes the first draft itself: a `session_end` hook reads the finished
  transcript and, when a verification command failed without a later pass
  or the person corrected the assistant, records a feedback record, freezes
  the workspace as a bounded fixture, and prints where the draft is and how
  to promote it. It never promotes, never touches a corpus, never blocks a
  session, and says nothing when neither signal fired.

  Three ways in, one code path:

    * An Elixir host adds `CaptureExtension.hooks/1` to its session's
      `:hooks`.
    * `CaptureExtension.lmx/2` runs the ordinary `lmx` commands with the
      hook attached, for `mix run` from this directory.
    * `bin/capture` is a `sessionEnd` command hook for a prebuilt `lmx`,
      loaded with `--hooks hooks.json`; it reads the same transcript through
      the sessions directory.

  The hook reads the transcript from the store rather than counting tool
  callbacks as they happen: `Lemieux.Hooks` says observer callbacks are best
  effort and accounting should read entries, and the entry ids a feedback
  record anchors on only exist there.
  """

  require Logger

  alias CaptureExtension.Config
  alias CaptureExtension.Draft
  alias CaptureExtension.Signals
  alias Lemieux.CLI.Options
  alias Lemieux.Entry
  alias Lemieux.Hooks.Config, as: HooksConfig
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @doc """
  Hooks for `Lemieux.start_session/1`'s `:hooks`; options are `Config.new/1`'s.

  The hook prints its one line on stderr: under `lmx run`, stdout is the
  model's answer and nothing else.
  """
  @spec hooks(opts :: keyword()) :: Lemieux.Hooks.t()
  def hooks(opts \\ []) when is_list(opts) do
    config = Config.new!(opts)
    [session_end: fn _reason, context -> observe_end(context, config) end]
  end

  @doc """
  Reads a stored session and drafts a case when a signal fired.

  Returns `{:ok, nil}` for a clean session and for one the store has never
  seen; a session with no entries has nothing to draft.
  """
  @spec capture(session_id :: String.t(), cwd :: Path.t(), config :: Config.t()) ::
          {:ok, Draft.t() | nil} | {:error, term()}
  def capture(session_id, cwd, %Config{} = config)
      when is_binary(session_id) and is_binary(cwd) do
    store = config.store || JSONL.new(config.sessions_dir)

    case Store.read(store, session_id) do
      {:ok, entries} -> capture_entries(entries, %{session_id: session_id, cwd: cwd}, config)
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Drafts a case from transcript entries already in hand."
  @spec capture_entries(
          entries :: [Entry.t()],
          session :: %{session_id: String.t(), cwd: Path.t()},
          config :: Config.t()
        ) :: {:ok, Draft.t() | nil} | {:error, term()}
  def capture_entries(entries, %{session_id: _id, cwd: _cwd} = session, %Config{} = config)
      when is_list(entries) do
    case Signals.detect(entries, config) do
      [] -> {:ok, nil}
      signals -> Draft.write(signals, entries, session, config)
    end
  end

  @doc """
  Runs an `lmx` command with the capture hook attached.

  `mix run -e 'CaptureExtension.lmx(System.argv())' -- run "fix the tests"`
  from this directory is `lmx run` with capture enabled. The hook reads the
  same sessions directory the command writes, including one chosen with
  `--sessions-dir`, and a `--hooks FILE` given on the command line still
  loads. Options are `Config.new/1`'s; anything else is passed to
  `Lemieux.CLI.run/2`.
  """
  @spec lmx(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def lmx(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    {capture_opts, cli_opts} = Keyword.split(opts, Config.option_names())

    with {:ok, options} <- Options.parse(argv),
         {:ok, file_hooks} <- file_hooks(options) do
      capture_opts = Keyword.put_new(capture_opts, :sessions_dir, options.sessions_dir)
      hooks = hooks(capture_opts) ++ file_hooks ++ Keyword.get(cli_opts, :hooks, [])

      Lemieux.CLI.run(argv, Keyword.put(cli_opts, :hooks, hooks))
    else
      {:error, message} ->
        IO.puts(:stderr, "lmx: #{message}")
        {:error, 1}
    end
  end

  defp file_hooks(%Options{hooks_config: nil}), do: {:ok, []}
  defp file_hooks(%Options{hooks_config: path}), do: HooksConfig.read(path)

  defp observe_end(%{session_id: session_id, cwd: cwd}, config) do
    case capture(session_id, cwd, config) do
      {:ok, nil} ->
        :ok

      {:ok, %Draft{line: line}} ->
        IO.puts(:stderr, line)

      {:error, reason} ->
        Logger.warning("capture: session #{session_id} was not drafted: #{inspect(reason)}")
    end
  end
end

defmodule Lemieux.Session do
  @moduledoc """
  The process that owns one running agent.

  A session holds a transcript, talks to a `Lemieux.Provider`, and is the only
  writer of its `Lemieux.Store`. It is the effectful half of the loop;
  `Lemieux.Turn` is the pure half that decides what any of it means. Nothing
  in `handle_info/2` decides anything — it folds the event and does what the
  effects say — and keeping it that way is what keeps the loop's rules
  testable without a process.

  ## The session outlives whoever is watching it

  Events go to every subscriber pid as `{:lemieux, session_id, event}`, and a
  subscriber is only an address. It is not linked and not required: a session
  with no subscribers runs and persists exactly the same way. Subscribers are
  monitored solely so dead watcher pids can be discarded. A CLI that exits, a
  LiveView that disconnects, or a host that restarts does not stop the agent or
  lose its work. `subscribe/2` attaches a new watcher to a running session.

  Plain messages rather than a pub-sub library, because a dependency that
  exists to fan one message out to n listeners is the host's choice to make.
  A host that wants `Phoenix.PubSub` subscribes one process and broadcasts
  from it; a CLI just receives.

  ## Events a subscriber sees

    * `{:entry, entry}` — an entry was persisted. Emitted for every entry,
      including the user's own prompt, so a subscriber that renders only what
      it is told stays in step with the store.
    * `{:text_delta, %{id:, text:}}`, `{:thinking_delta, %{id:, text:}}` — as
      they stream. `id` is the assistant entry these chunks become, so a host
      can replace a transient buffer when the `{:entry, entry}` arrives.
    * `{:tool_delta, %{call_id:, name:, text:}}` — transient output from a
      streaming tool. The final bounded result is persisted separately.
    * `{:tool_call, call}` — the model asked for a tool, before it runs.
    * `{:tool_receipt, %{call_id:, name:, receipt:}}` — a running tool left a
      receipt for a remote effect it has just committed. See
      `Lemieux.Tool.Receipt`.
    * `{:tool_approval, call}` — a hook parked this call; it will not run
      until `resolve_tool/3` answers, or the timeout denies it.
    * `{:question, question}` — a tool asked something; `answer/3` replies.
    * `{:usage, payload}` — token and cost accounting for the request. See
      `Lemieux.Usage` for the guaranteed keys.
    * `{:harness_snapshot, snapshot}` — the verified effective harness for the
      next request, also persisted as a `:harness_snapshot` entry.
    * `{:run_evidence, manifest}` — exactly one terminal evidence manifest for
      an accepted prompt, emitted and persisted before `:finished`.
    * `{:context, position}` — a `Lemieux.Context`, sent once per prompt just
      before `:finished`, so a status line has somewhere to come from without
      asking for a whole snapshot after every turn.
    * `{:compacted, %{summary:, entries:, sections:, tokens:, usage:, trigger:}}` — the elder
      conversation was summarised and has stopped being sent. It is still in
      the transcript. `sections` is what `Lemieux.Compaction.sections/1`
      read back when `:summary_sections` was on, or `nil`. `tokens` is
      `Lemieux.Context.compacted/4`'s `%{before:, after:}` — the position
      measured just before the cut, and an apportioned estimate of where it
      leaves the window — or `nil` when there was nothing measured to compare
      against. Measured here because it cannot be measured after: the
      compaction entry makes the position unmeasured until the next
      response.
      `usage` is the summarizing request's actual reported usage and cost;
      `trigger` identifies the threshold, price, advisory, manual, or overflow
      decision. A projected saving is a forecast, never a billed amount.
    * `{:compaction_planned, %{trigger:, forecast:}}` — a preflight chose to
      summarize before dispatch. Price decisions include their projected
      savings; the later usage events carry actual spend.
    * `{:cleared, %{entries:}}` — `clear/1` stopped the conversation so far
      from being sent, with nothing standing in for it. Also still in the
      transcript.
    * `{:compaction_failed, reason}` — summarising did not work. Nothing was
      cut. The threshold is not tried again for a few requests, a number that
      doubles with each consecutive failure; `compact/2` is always available.
    * `{:context_recovery, %{action: :compact_and_retry, reason: reason}}` — a
      provider identified a context-window overflow before producing output,
      so the session is making its one safe compaction-and-retry attempt.
    * `{:context_window_unknown, %{model:, fallback:}}` — nobody knows how
      large this model's window is, so automatic compaction sizes itself
      against `fallback` tokens instead (or is off, when `fallback` is `nil`).
      Sent once per model: before the model's first request, so a host that
      subscribes when it prompts hears it, and on a model change.
    * `{:context_window_small, %{model:, window:, overhead:, source:}}` — the
      known window leaves less than 8,192 tokens beyond the session's own
      instructions and tools (`overhead`, estimated). `source` is where the
      window came from: `:configured`, `:provider`, `:stated` by a refusal,
      or `:served`, reported by the endpoint after an answer. Sent once per
      model and window, before a request or when a window is learned. When
      even `overhead` is over the compaction threshold, the threshold is not
      tried: no summary could get under it.
    * `{:compaction_ineffective, %{input_tokens:, threshold:, window:, retry_in:}}` —
      the request built after an automatic compaction was still over the
      threshold, so the summary made no room. The threshold is not tried
      again for `retry_in` requests, the longest step of the failure backoff;
      `compact/2` is always available. A successful summary, `clear/1`, a
      model change or a new window the endpoint reports serving forgets the
      wait; a window learned from a refusal does not.
    * `{:provider_retry, %{attempt:, max:, delay_ms:, category:, reason:, after_output:}}` —
      the request failed with a failure the provider may not repeat (a 5xx,
      a rate limit, a stalled stream), and the session will send it again
      after `delay_ms`. `reason` keeps the typed value. No error entry is
      written for a retried failure; the request that follows records it
      under `retry` in its snapshot. `after_output` says the model had
      already started answering: what it had said is kept on the transcript
      as an assistant entry marked `"partial" => true`, which is never sent
      again, and the request is answered afresh.
    * `{:tool_call_delta, %{id:, name:, bytes:, head:}}` — the model is
      composing a tool call: its name, how many bytes of arguments have
      arrived, and their first bytes. Transient, like the text deltas, and
      the only sign of life while a model writes a long file.
    * `{:error, reason}` — the turn failed. Provider failures retain their
      original typed value; use `Lemieux.Provider.Error.message/1` at a human
      presentation boundary. Always followed by `:finished`.
    * `{:response_metadata, metadata}` — ephemeral response facts for a
      provider attempt, correlated with its request entry via `:request_id`.
      Forwarded before terminal handling, including failures and compaction.
      It is neither transcript data nor semantic progress for retry policy.
    * `{:route_observation, observation}` — an optional, later route-owned
      notice. It is informational, never a usage or spending event.
    * `{:finished, stop_reason}` — the work is over and the session is idle.
    * `{:tools_changed, previous, current}` — `set_tools/2` replaced the
      local catalog; both are lists of tool names.
    * `{:tool_access_changed, :enabled | :disabled, names, current}` —
      `enable_tools/2` or `disable_tools/2` changed what the model may call;
      `current` is the local catalog's names after the change.
    * `{:model_changed, previous, current}` — `set_model/2` or
      `set_provider/2` took effect for future requests.
    * `{:reasoning_effort_changed, previous, current}` — as strings, with
      `"default"` standing for none.
    * `{:mcp_error, {:invalid_tool_catalog, reason}}` — an MCP server offered
      tools the catalog could not accept; requests go on with the local
      tools and without them.
    * `{:mcp_server, status}` — one configured server's connection moved on:
      `status` is `mcp_server_status/0`, `:connecting` when its startup
      connection begins and `:connected`, `:failed` or `:needs_auth` when it
      settles. Its tools join the next request from then on.
    * `{:ready, %{mcp: statuses}}` — every startup MCP connection has
      settled. Sent once, and only by a session that had servers to connect;
      one without is ready when `start_session/1` returns, and `info/1`
      says which a session is.
    * `{:waiting_for_mcp, %{servers:, timeout_ms:}}` — a prompt arrived while
      servers were still connecting, and its first request is waiting up to
      `timeout_ms` for them rather than going without their tools.
    * `{:run_evidence_failed, %{run_id:, reason:}}` — the run's terminal
      evidence could not be built. The work is unaffected; a degraded
      `:run_evidence` entry records the failure in its place.
    * `{:subagent, path, event}` — a delegated child's event, nested. `path`
      is `[root_id]` for a group's lifecycle and `[root_id, child_id]` for a
      child's own events, which are the events listed here for the child's
      session. See `Lemieux.Subagent`.

  ## One prompt, many turns

  A prompt is not one request. The model answers, calls tools, reads their
  results, answers again — and the session stays busy across all of it,
  emitting `{:finished, _}` once, when the model stops asking for things. That
  is the unit a person waits for.

  The turns are bounded (`:max_turns`). A model that calls a tool, reads the
  result, and calls it again forever is not a hypothetical — it is what a bad
  prompt and a failing command produce together — and the bill for it arrives
  regardless. Hitting the bound ends the work honestly, with an entry saying
  so, rather than by running out of money.

  A bound is not a guard, though, and the loop that costs the most is the one
  that looks productive: the same denied command, or the same failing test,
  asked for again and again. So after every round of tool calls the session
  asks `Lemieux.Session.Guard` whether to go on, handing it what it remembers
  of recent rounds — see `note_wave/2` for why what came back is half of that
  record — and the shipped rule stops at `:no_progress` when three consecutive
  rounds asked for the same thing and got the same answer, and when half of
  the last eight calls repeated an earlier one with the same answer, which is
  the alternating loop (`a, b, a, b, …`) that identical rounds never catch.
  Those two rules, with the cost and request budgets, are what bound a
  runaway; `:guard` replaces them. The turn count is only a budget, and it is
  set high enough that a session working well does not meet it.

  ## One request, on somebody's behalf

  Between prompts a host may ask for one tool-free request of its own — a
  review of the transcript, a judgement on the run, a summary for a screen —
  with `aside/2`. It is recorded and billed like a turn and labelled with the
  kind the host chose; what it is *for* is the host's business, and the loop
  holds no opinion about it. `Lemieux.Session.Aside` says why that matters.

  `:max_cost_usd` is the stricter bound: immediately before every provider
  request and externally billed tool call, the session adds a pessimistic
  estimate to measured session spend. Parallel tool batches reserve their
  declared maxima together rather than each seeing the same remaining budget.
  If a request or tool would exceed the cap—or either amount is unknown—it is
  never started. This check cannot recover money already spent on an in-flight
  operation; its purpose is to make every next operation a decision rather
  than discovering the bill afterwards.

  ## Why the provider runs in a task

  `Lemieux.Provider.run/3` blocks for as long as the model is talking. Run
  inline, the session could not answer a snapshot, a steer or a cancel for the
  length of a turn — and cancelling a turn is exactly killing the thing that
  is blocked. The task runs under the runtime's `Task.Supervisor` and is linked
  to the trapping session. A provider crash arrives as a `:DOWN` message the
  session turns into an entry; a session crash takes its in-flight work down
  too, so a tool cannot become an orphan that keeps changing the workspace.

  ## Restarting is the host's decision, not the supervisor's

  Sessions are `restart: :temporary`. A supervisor that restarted one would
  replay the options it was started with, not the conversation it was having,
  producing a process with the same id and an empty transcript — the shape
  most likely to be mistaken for a working session. The transcript is on disk;
  a host that wants the work continued resumes it deliberately.
  """

  use GenServer, restart: :temporary

  alias Lemieux.Context
  alias Lemieux.Entry
  alias Lemieux.Evidence.Run, as: RunEvidence
  alias Lemieux.Harness.Snapshot, as: HarnessSnapshot
  alias Lemieux.Hooks
  alias Lemieux.MCP
  alias Lemieux.OpenTelemetry
  alias Lemieux.Session.Aside
  alias Lemieux.Session.Await
  alias Lemieux.Session.Boot
  alias Lemieux.Session.Calls
  alias Lemieux.Session.Document
  alias Lemieux.Session.Mailbox
  alias Lemieux.Session.Prompts
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Tool
  alias Lemieux.Tool.Profile
  alias Lemieux.Usage

  # A budget, not a guard: the repeat rules catch loops, and this bounds what a
  # prompt that never loops may cost in requests. It used to be fifty, which was
  # under three minutes of work at the turn rate a capable model takes over a
  # read-heavy task — a session working well stopped at a count nobody chose. Four
  # hundred is set where a session doing well on a long task never meets it.
  @max_turns 400

  # Late enough that most sessions never reach it, early enough that the
  # summarising request itself still fits in what is left of the window.
  @compact_at 0.8

  @doc "Default context fraction at which the prepared request is auto-compacted."
  @spec default_compact_at() :: float()
  def default_compact_at, do: @compact_at

  # The largest window compaction plans against. A model with a million-token
  # window used to be compacted at 800,000 tokens, which a person meets as a
  # session that got slow, expensive and forgetful long before anything was
  # summarised. Past a couple of hundred thousand tokens a window is room to
  # recover in, not room to work in.
  @window_cap 200_000

  # Stubbing old tool output; `Lemieux.Compaction.applied/2` says what each is.
  @stub_keep 40
  @stub_batch 20
  @stub_min_bytes 4_096

  # How many attachment-carrying prompts keep their attachments in a request.
  # Enough that a conversation about a file still has the file while it is the
  # subject, few enough that a long session does not re-send every file it was
  # ever shown. `Lemieux.Compaction.applied/2` says what the older ones carry.
  @keep_attachments 3

  # The same for images and documents tools returned — screenshots, mostly,
  # which a browser session produces one of per step. Also the batch they are
  # shed in, so the cached prefix changes once per this many new ones.
  @keep_media 4

  # A session's configuration, declared once, because it lives in three places
  # that have to agree: what the transcript records, what a resume restores, and
  # what a command passes. Missing the third is how a session deliberately given
  # fewer tools got them all back by being resumed.
  #
  # `:cwd` is recorded and deliberately not restored — location is not behaviour.
  # Identity is not here at all: adding `root_session_id` once made every fork
  # record a new configuration entry, because a fork's root really is different
  # from its source's. `Lemieux.Transcript.delegated?/2` answers that question
  # instead.
  @restored ~w(model system tools disabled_tools mcp_servers params reasoning_effort)a
  @recorded_only ~w(cwd tool_profile harness_assembly)a
  @configuration @restored ++ @recorded_only
  @typedoc "How to address a session: its pid, or a `:via` tuple."
  @type session :: GenServer.server()

  @typedoc "What `snapshot/1` reports."
  @type snapshot :: %{
          id: String.t(),
          status: :idle | :busy,
          model: String.t(),
          provider: String.t() | nil,
          reasoning_effort: String.t(),
          reasoning_efforts: [String.t()],
          tools: [String.t()],
          cwd: Path.t(),
          pending: [%{call_id: String.t(), kind: atom(), payload: term()}],
          queued_steers: [String.t()],
          queued_follow_ups: [String.t()],
          request_id: String.t() | nil,
          spent_usd: number() | nil,
          inclusive_spent_usd: number() | nil,
          usage: %{
            direct: Usage.t(),
            delegated: Usage.t(),
            total: Usage.t()
          },
          max_cost_usd: number() | nil,
          harness_snapshot: HarnessSnapshot.t() | nil,
          run_evidence: RunEvidence.t() | nil,
          entries: [Entry.t()],
          context: Context.t(),
          params: keyword(),
          harness_context: map(),
          supervisor: atom()
        }

  @typedoc "A tool currently available to this session and whether the model may call it."
  @type tool_status :: %{
          name: String.t(),
          source: :local | {:mcp, String.t()},
          allowed?: boolean(),
          enabled?: boolean()
        }

  @typedoc """
  Where one configured MCP server's connection stands.

  `:connecting` while its startup connection runs; `:connected` with tools;
  `:needs_auth` when it wants somebody's OAuth consent before it will answer;
  `:failed` otherwise, with `error` saying why; `:disabled` when this session
  turned it off. `notices` says which of its tools were renamed or left out
  and why; `auth` is where a `:needs_auth` server wants somebody to sign in
  (`Lemieux.MCP.connect_server/2`'s `info`), or `nil`.
  """
  @type mcp_server_status :: %{
          name: String.t(),
          transport: String.t() | nil,
          status: :connecting | :connected | :needs_auth | :failed | :disabled,
          tool_count: non_neg_integer(),
          error: String.t() | nil,
          notices: [String.t()],
          auth: map() | nil
        }

  @typedoc """
  What `info/1` reports: `snapshot/1` without the transcript.

  `requests` counts direct provider requests so far, which is what
  `max_requests` bounds. `ready?` is false while startup MCP connections are
  still running; `mcp` is where each stands. `context_window_known?` is false
  when compaction is sizing itself against the fallback.
  """
  @type info :: %{
          id: String.t(),
          status: :idle | :busy,
          model: String.t(),
          provider: String.t() | nil,
          reasoning_effort: String.t(),
          reasoning_efforts: [String.t()],
          tools: [String.t()],
          cwd: Path.t(),
          pending: [%{call_id: String.t(), kind: atom(), payload: term()}],
          queued_steers: [String.t()],
          queued_follow_ups: [String.t()],
          request_id: String.t() | nil,
          requests: non_neg_integer(),
          max_requests: pos_integer() | nil,
          spent_usd: number() | nil,
          max_cost_usd: number() | nil,
          usage: %{direct: Usage.t(), delegated: Usage.t(), total: Usage.t()},
          context: Context.t(),
          context_window_known?: boolean(),
          ready?: boolean(),
          mcp: [mcp_server_status()]
        }

  @doc """
  Starts a session.

  ## Options

    * `:provider` — required, a `Lemieux.Provider`.
    * `:store` — required, a `Lemieux.Store`.
    * `:model` — a `req_llm` model specification. Required for a new session;
      a resumed one takes it from the transcript unless it is passed.
    * `:id` — the session id, defaulting to a fresh `Lemieux.ID`. A host that
      has its own identifiers passes one.
    * `:supervisor` — the mounted `Lemieux.Supervisor`'s name.
    * `:subscriber` — a pid or list of pids to send events to, or `nil`.
    * `:system` — the system prompt, defaulting to `Lemieux.Prompt.default/0`.
    * `:params` — generation parameters passed through to the provider.
    * `:output_schema` — an optional req_llm structured-output schema for
      validated final results. This executable host choice is not restored.
    * `:reasoning_effort` — an explicit reasoning effort, as a string, or nil
      to use the model's default. Recorded and restored independently from the
      rest of `:params` because it can be changed interactively.
    * `:entries` — a transcript to start from, for a resumed session.
    * `:tools` — the tools the model may call, defaulting to
      `Lemieux.Tools.default/0`. A host that wants the model able to delegate
      builds a `Lemieux.Subagent.Delegate` and passes it here; it is the one
      tool that is never restored, and the tool's documentation says why.
    * `:host_tools` — runtime tools appended by the current host. They are
      validated and governed like configured tools, but are neither recorded
      nor restored; the current host must re-supply them. Use this for
      ephemeral capabilities such as an allowlisted content loader.
    * `:disabled_tools` — names from the available catalog to withhold from
      future requests. Recorded and restored so a resume cannot silently
      widen the session's capabilities.
    * `:tool_profile` — a host-resolved `Lemieux.Tool.Profile` or JSON map.
      Its allowlist narrows local and MCP catalogs; shared profiles leave
      dangerous opt-in tools such as `elixir` off unless explicitly named.
      The profile and `enabled_by` evidence are recorded, but authority is
      never restored from a transcript: the current host must pass it again.
    * `:tool_timeout_ms` — host maximum for any one tool task. Descriptor
      deadlines may be lower. Defaults to one hour, which is what lets a
      `delegate` call wait for a fan-out that runs for tens of minutes; a
      tool that names a shorter deadline in its descriptor keeps it. Each
      tool is told the deadline it actually got as `deadline_ms` in its
      context, so one that waits on something else can hand that something
      a shorter clock.
    * `:approval_timeout` — how long a parked approval, `ask_user` question or
      MCP elicitation waits, or `:infinity` for a host where somebody is
      always there to answer eventually. Defaults to five minutes. The tool's
      own deadline is paused while it is parked: a person taking three
      minutes over an approval must not find the call already timed out when
      they say yes.
    * `:tool_output_bytes` — host maximum for model text and structured audit
      evidence from one tool. Descriptor limits may be lower. Defaults to
      120,000 bytes; `bash` bounds itself at 30,000 and `read` at 60,000
      regardless, so the default mostly decides how much a `delegate` call
      may bring back — three investigations at 32 KiB each, with their
      envelopes.
    * `:provider_retry` — how a failed request is retried when the failure is
      one the provider may not repeat: an HTTP 5xx, an overload, a rate limit,
      or a stream that went quiet. A keyword list with `:max_attempts` (6),
      `:base_delay_ms` (2,000, doubling per attempt), `:max_delay_ms`
      (60,000) and `:after_output` (true); a `retry-after` the provider sends
      wins over the backoff. `false` turns it off. A request that had already
      produced output is retried too, because nothing it produced has run:
      tool calls only run once a response is complete, so the partial answer
      is kept on the transcript as a record, marked partial and never sent,
      and the request is sent again without it. `after_output: false` keeps
      the older rule that such a request ends the turn. Quota and
      authentication failures are never retried: waiting does not refill an
      account or fix a key. `retry/1` is the manual path for a failure that
      outlasted the attempts. Retries consume request and turn limits. If
      those limits or the cost budget cannot admit another attempt, the
      original provider error ends the turn without backoff. Preparation runs
      again with `context.retry` set to its retry note. Hosts with an
      external retry scheduler should set `provider_retry: false`; this
      policy is independent of retries configured inside the provider.
    * `:tool_token_counter` — optional `(model, serialized_catalog) ->
      {:ok, tokenizer, count}` callback. When supplied, exact catalog token
      measurements join the request snapshot; otherwise count/tokenizer stay
      explicitly unknown rather than being guessed.
    * `:messages` — the module the loop's own sentences to the model come
      from: tool denials, timeouts, the catalog notice, why the work stopped.
      Defaults to `Lemieux.Messages`, which says what each one is for. Host
      behaviour like `:hooks`: neither recorded nor restored.
    * `:compaction` — how the elder conversation is summarised: a module
      implementing `Lemieux.Compaction`, or `{module, state}`. Defaults to
      `Lemieux.Compaction`. The module decides where to cut, what the
      summariser is asked and how its answer is put in front of later
      requests; *when* stays here — the threshold, `compact/2` and a
      provider's context-limit refusal all fire only between turns. Neither
      recorded nor restored.
    * `:guard` — what decides, after each round of tool calls, whether the
      loop goes on: a module implementing `Lemieux.Session.Guard`, or
      `{module, state}`. The default stops a round that has come back the
      same three times, a window whose calls mostly repeat earlier ones, and
      a prompt that has spent `:max_turns`. Neither recorded nor restored.
    * `:hooks` — policy, see `Lemieux.Hooks`.
    * `:cwd` — the directory tools run in, defaulting to the current one.
    * `:environment` — the `Lemieux.Environment` used by bundled tools,
      defaulting to `Lemieux.Environment.Local`. The default is deliberate
      where the tools' own fallback was not: a library that ran nowhere until
      told where would fail every first embedding, and a session's location
      is the host's to choose, not to forget. Below this option nothing
      assumes the local machine — `Lemieux.Environment.from_context/1` and
      `Lemieux.Background.start/1` raise without one — and the harness
      snapshot records which environment was in force, so an audit can see
      when a host left the choice to the default. Host-owned executable
      configuration is neither recorded nor restored.
    * `:mcp_servers` — the MCP servers to connect once the session is up, as
      the configuration maps `Lemieux.MCP.config/1` normalises. Recorded and
      restored like `:tools`; `add_mcp_servers/2` adds to a running session.
    * `:mcp_auth` — a `Lemieux.MCP.Auth` deciding how this host authorizes
      against a server that answers with an OAuth challenge, or `nil` to stop
      at the challenge and report it. A seam like `:hooks`: it holds a
      credential store and a redirect function, so it is neither recorded
      nor restored, and a resumed session gets the resuming host's.
    * `:clock` — where the session's timers and deadlines come from: tool
      deadlines, approval and question timeouts, the MCP startup grace, and
      provider- and summary-retry backoff. A `Lemieux.Clock`; `nil` (the
      default) is the real one. A test passes a `Lemieux.Clock.Manual` and
      moves time itself, so a busy machine cannot make a deadline fire early
      or late.
    * `:evidence` — how much of its own audit record the session writes.
      `:full` (the default) records every request's prompt, tool schemas and
      catalog, a harness snapshot per run and a terminal evidence manifest.
      `:digests` keeps request snapshots' digests, sizes, entry ids and
      parameters but not the prompt text or schemas. `:off` also writes no
      harness snapshots or run evidence; reflection and harness verification
      then have nothing to read.
    * `:transcript_dedup` — `true` (the default) to write each large value
      a request or harness snapshot repeats — the system prompt, the tool
      schemas and catalog — once, and refer to it afterwards; see
      `Lemieux.Transcript.Dedup`. `false` for a host whose own readers see
      its store's entries without going through `Lemieux.Transcript.expand/1`.
    * `:mcp_transports` — optional map from a transport name to a module
      implementing `Lemieux.MCP.Transport`, merged over `Lemieux.MCP.transports/0`
      so a host can add or replace a transport without editing the library.
      Neither recorded nor restored: a module name means nothing in a host
      that lacks the module.
    * `:mcp_stdio_launcher` — optional host-owned function receiving
      `(command, args, env, cwd)` and returning `{:ok, port}` or
      `{:ok, %{port: port, close: close_fun}}` for stdio MCP servers. It is
      neither recorded nor restored. A sandboxing host uses this seam to own
      executable lookup, environment filtering, mounts, network policy,
      stderr bounds and process termination.
    * `:mcp_connect_opts` — extra options passed to `Lemieux.MCP.connect_report/2`
      for every server this session connects, after the session's own. A
      host passes `interactive_auth: false` here to have a server that needs
      somebody's OAuth consent reported as `:needs_auth` instead of waited on.
    * `:mcp_grace_ms` — how long a prompt that arrives while startup MCP
      connections are still running waits for them before its first request
      goes without their tools, measured from when the session started.
      Defaults to 15,000; `:infinity` always waits, which is what a session
      did before servers connected in the background. Servers connect off
      the session process either way, so it answers snapshots and cancels
      while they do.
    * `:transcript_lock` — whether the session claims its transcript through
      `Lemieux.Store.lock/2`, so a second session on the same id — another
      terminal resuming it — is refused instead of interleaving its writes.
      Defaults to true; a store that does not implement locking is
      unaffected. `start_session/1` returns
      `{:error, {:session_locked, holder}}` when the claim is refused, where
      `holder` is `%{host: String.t(), os_pid: String.t() | nil,
      process: String.t() | nil, since: String.t() | nil, path: String.t()}` —
      who holds it, since when, and the lock file to delete if that process
      is gone.
    * `:max_requests` — optional positive session-wide limit over direct provider
      requests, including retries, compaction and restored requests. Independent of prices.
      Hosts must resupply this execution policy when resuming a transcript.
    * `:max_turns` — how many model requests one prompt may take before the
      session stops on its own. Defaults to #{@max_turns}.
    * `:max_cost_usd` — maximum measured plus estimated provider and native
      tool spend for the whole session. A provider request that would exceed it
      ends the turn with `{:budget, payload}`; a tool call that would exceed it
      becomes a budget-denied tool result. Unknown pricing also stops rather
      than being treated as free. Disabled by default.
    * `:context_window` — how many tokens this model's window holds. Asked of
      the provider when not given, and `nil` when even it does not know. A
      window the provider reports serving after an answer
      (`{:context_window, tokens}`, a local Ollama daemon's) replaces an
      asked one and bounds a given one: compaction never plans past what
      the server keeps.
    * `:context_window_fallback` — the window automatic compaction sizes
      itself against when `:context_window` is `nil`. Defaults to
      `Lemieux.Provider.fallback_context_window/0`, a common window, so an
      unknown model still compacts rather than running until the provider
      refuses; `nil` keeps compaction off for such a model. A model whose
      refusal states its window (see
      `Lemieux.Provider.Error.stated_context_window/1`) is sized against that
      from then on. `{:context_window_unknown, _}` says when the fallback is
      in use.
    * `:provider_limiter` — provider admission, as `{module, ref}` where the
      module implements `Lemieux.Provider.Admission`. Defaults to what the
      mount registered, `Lemieux.ProviderLimiter` unless the host chose
      otherwise; a bare pid or name means that limiter. Pass the same value to
      several runtimes when they share one credential/rate domain, or `nil` to
      disable admission.
    * `:provider_limit_key` — the rate-domain key, or a function from
      `(provider, model)` to a key. The default separates provider modules,
      provider names, and models inside this runtime.
    * `:root_session_id` — the root whose requests share fair admission. Child
      sessions inherit their parent's root id; ordinary sessions use their id.
      It also marks delegation: a session whose root id names another session
      is treated as a delegated subagent, so its Claude Code `SessionStart`
      hook commands do not run (`Lemieux.Hooks.session_start/3`). Leave it
      unset, or the session's own id, on a top-level session; to put several
      sessions in one rate domain, give them the same `:provider_limit_key`
      instead.
    * `:harness_context` — JSON-shaped host identifiers for resolved assets,
      hook/workflow/environment/sandbox profiles, and optional extensions.
      Executable hooks and environments remain separate runtime seams.
    * `:correlation_ids` — opaque host correlation ids copied to snapshots and
      run evidence. They are integrity-protected but excluded from the
      behavior digest. Lemieux always supplies session/root/run ids.
    * `:evidence_artifacts` — caller-authorized digest-bearing artifact
      references to attach to terminal run evidence. Lemieux never resolves
      their locators.
    * `:auto_compaction` — whether automatic threshold, price, advice or
      context-error compaction can start. Defaults to true; explicit
      `Session.compact/2` remains available when false.
    * `:compact_at` — the fraction of the window at which to compact the
      prepared request, or `nil` to disable the threshold. Defaults to #{@compact_at}.
    * `:compaction_window_cap` — the most tokens of any window the threshold
      and the default retained tail are sized against. Defaults to
      #{@window_cap}, so a model with a million-token window compacts at
      #{round(@window_cap * @compact_at)} tokens rather than at 800,000:
      long before a window that size fills, the model is slower, dearer and
      worse at finding what matters in it. `nil` uses the whole window.
    * `:input_token_counter` — an optional bounded function from a prepared
      `Lemieux.Request` to `{:ok, tokens}` or `:unknown`. Without one, the
      preflight projects from provider usage and encoded request size.
    * `:keep` — roughly what fraction of the conversation compaction keeps,
      by entry count. See `Lemieux.Compaction.plan/2`.
    * `:keep_recent_tokens` — estimated token target for the retained
      conversation. Takes precedence over `:keep` with the shipped strategy.
      When neither is set, the shipped plan sizes the retained tail from the
      capped window it is handed (see `Lemieux.Compaction.plan/2`), which is
      what lets a single prompt followed by a long run of tool calls be
      compacted at all.
    * `:stub_tool_results` — how old tool output is left out of requests;
      see `Lemieux.Compaction.applied/2`. Defaults to stubbing results older
      than the newest #{@stub_keep}, #{@stub_batch} at a time, when their
      output exceeds #{@stub_min_bytes} bytes; `false` sends every result
      whole until compaction.
    * `:keep_attachments` — how many `@`-reference-carrying prompts keep their
      attachments in the request, newest first. Defaults to
      #{@keep_attachments}; `:all` never sheds. See
      `Lemieux.Compaction.applied/2`.
    * `:keep_media` — how many image- or document-carrying tool results keep
      their attachments in the request, newest first, shed #{@keep_media} at a
      time so a cached prefix changes once per #{@keep_media} new images.
      Defaults to #{@keep_media}; `:all` never sheds. See
      `Lemieux.Compaction.applied/2`.
    * `:input_modalities` — what the model can be shown besides text, as
      the model catalog names it (`[:text, :image, :pdf]`), overriding the
      provider's answer. Tools attach images and PDFs only for a model known to
      read them (`Lemieux.Tool.Attachment`), and the provider is asked again
      on every call because the model can change; a host serving a local
      vision model the catalog has never heard of says so here.
    * `:summary_sections` — ask the summariser for structured `open work`,
      `dependencies`, `decisions` and `verification debt` sections, and
      record what it wrote. Defaults to `false`; `Lemieux.Compaction` says
      what the option is for and why it is off.
    * `:summary_model` and `:summary_params` — optional model and generation
      parameters for the summarizing request, using the same provider route.
      The request remains subject to the session's request and cost budgets.
    * `:summary_max_bytes` — maximum accepted summary size. Defaults to 32768;
      an overlong answer leaves the full transcript intact.
    * `:compaction_price_tiers` — a map from resolved model name to price
      bands (`Lemieux.Compaction.Price`). A profitable move below a price
      cliff can trigger compaction before the window threshold. Empty by default.
    * `:compaction_expected_output_tokens` and
      `:compaction_minimum_savings_usd` — conservative inputs to that price
      decision. Defaults to zero expected output and positive net savings.
  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.get_lazy(opts, :id, &Lemieux.ID.generate/0)
    supervisor = Keyword.get(opts, :supervisor, Sup)
    name = {:via, Registry, {Sup.registry(supervisor), id}}

    result =
      GenServer.start_link(
        __MODULE__,
        Keyword.merge(opts, id: id, supervisor: supervisor),
        name: name
      )

    # Bind only after init succeeds: a rejected child must not leave a parent
    # context behind for another session that later reuses the same id.
    if match?({:ok, _session}, result) do
      OpenTelemetry.bind_prompt_parent(
        id,
        Keyword.get(opts, :open_telemetry_parent_contexts, [])
      )
    end

    result
  end

  @doc """
  Every part of a session's configuration that a `:session` entry records.
  """
  @spec configuration_keys() :: [atom()]
  def configuration_keys, do: @configuration

  @doc """
  The parts a resume takes from the transcript when it was not asked for
  something else.

  A host that builds session options — `Lemieux.CLI.Runtime` is one — should
  pass none of these when resuming unless somebody actually asked for them.
  Passing its own defaults instead is how a resumed session ends up configured
  as something it never was.
  """
  @spec restored_keys() :: [atom()]
  def restored_keys, do: @restored

  @doc """
  Returns the session's id.
  """
  @spec id(session :: session()) :: String.t()
  def id(session), do: GenServer.call(session, :id)

  @doc """
  Adds a process to the live event stream.

  Subscription is idempotent and affects only future events. The process is
  monitored but not linked; its death only removes the stale subscription.
  After a watcher restart, read the transcript for missed durable entries and
  subscribe its replacement pid.
  """
  @spec subscribe(session :: session(), subscriber :: pid()) :: :ok
  def subscribe(session, subscriber) when is_pid(subscriber),
    do: GenServer.call(session, {:subscribe, subscriber})

  @doc """
  Removes a process from the live event stream.

  Unsubscribing a process that is not attached is an idempotent success.
  """
  @spec unsubscribe(session :: session(), subscriber :: pid()) :: :ok
  def unsubscribe(session, subscriber) when is_pid(subscriber),
    do: GenServer.call(session, {:unsubscribe, subscriber})

  @doc """
  Sends a prompt, starting a turn.

  Returns as soon as the turn has started; the answer arrives at the
  subscriber. Returns `{:error, :busy}` when a turn is already running: a
  second prompt would be folded into a request that has already been sent, and
  silently dropped. `steer/2` is how you speak to a session that is working.
  """
  @spec prompt(session :: session(), text :: String.t()) ::
          :ok
          | {:error, :busy | :cancelled}
          | {:error, {:hook_denied, String.t()} | {:hook_failed, term()}}
  def prompt(session, text) when is_binary(text) do
    contexts = OpenTelemetry.capture_contexts()
    GenServer.call(session, {:prompt, text, contexts}, :infinity)
  end

  @doc """
  Runs one tool-free model request on a host's behalf, between turns.

  An aside is what a review, a judgement or a summary-for-a-screen has in
  common once the words are taken out: its own system text, its own entries
  or the transcript's, an optional output schema, and a kind to record it
  under. See `Lemieux.Session.Aside` for the fields. It goes the way a turn
  goes — the `user_prompt` hook sees its text, the request passes the budget
  gate and is written with its harness snapshot, the answer streams to the
  subscribers and lands in the transcript, and `{:finished, _}` says when it
  is over — with the differences a one-off request needs: it is never
  compacted first, its text is not expanded for `@`-references, a steer
  typed while it runs waits for the next prompt, and a stop hook's veto ends
  it rather than starting a repair loop. Tools are refused whatever the
  model or a `prepare_next_turn` hook asks; a call the model makes anyway is
  answered with a denial and the aside ends in `:error`.

  This is a facility and not a mode on purpose. Reflection was a mode — a
  flag the loop read at nine points — and every host that wanted a different
  review prompt, or a host-side judge scoring a run, would have had to be a
  third. A host that wants one writes a caller, as `Lemieux.Reflection.reflect/2`
  does, and the loop learns nothing about it.

  Returns as soon as the request has started. `{:error, :busy}` while a turn,
  a compaction or another aside is running: a busy session is never
  interrupted implicitly. The hook errors are `prompt/2`'s.
  """
  @spec aside(session :: session(), aside :: Aside.t()) ::
          :ok
          | {:error, :busy | :cancelled}
          | {:error, {:hook_denied, String.t()} | {:hook_failed, term()}}
  def aside(session, %Aside{} = aside) do
    GenServer.call(session, {:aside, aside, OpenTelemetry.capture_contexts()}, :infinity)
  end

  @doc """
  Re-reads every file this conversation attached with an `@`-reference.

  Anything whose contents have moved on is attached again, as a new prompt
  saying which files changed — which is the only shape a transcript allows.
  Entries are immutable, so there is no rewriting the turn that carried the
  old version, and there should not be: what the model was shown, and answered
  from, is exactly the durable fact a transcript is for.

  Answers `{:ok, count}` with how many files were re-attached. Zero means
  nothing had changed and nothing was written; a turn starts only when
  something did.
  """
  @spec refresh(session :: session()) ::
          {:ok, non_neg_integer()} | {:error, :busy | :cancelled | {:refresh_failed, term()}}
  def refresh(session), do: GenServer.call(session, :refresh, :infinity)

  @doc """
  Lists models the session's provider reports as currently available.

  The current model is included when the provider still validates it. That
  keeps usable local and custom models, which may be absent from a catalog,
  without advertising a resumed remote model after its credential was removed.
  """
  @spec available_models(session :: session()) :: [String.t()]
  def available_models(session), do: GenServer.call(session, :available_models)

  @doc "Lists compatible models belonging to one provider."
  @spec available_models(session :: session(), provider :: String.t()) :: [String.t()]
  def available_models(session, provider) when is_binary(provider),
    do: GenServer.call(session, {:available_models, provider})

  @doc "Returns optional provider presentation metadata for the model picker."
  @spec model_metadata(session :: session()) :: %{optional(String.t()) => map()}
  def model_metadata(session), do: GenServer.call(session, :model_metadata)

  @doc "Lists providers with at least one compatible model available."
  @spec available_providers(session :: session()) :: [String.t()]
  def available_providers(session), do: GenServer.call(session, :available_providers)

  @doc """
  Changes the model used by future turns.

  A model cannot change while the session is busy: a tool-followup request is
  part of the turn that produced it, and changing providers between those two
  requests would split one turn across two models. Successful changes are
  persisted as session configuration and restored on resume.
  """
  @spec set_model(session :: session(), model :: String.t()) ::
          {:ok, String.t()} | {:error, :busy | term()}
  def set_model(session, model) when is_binary(model),
    do: GenServer.call(session, {:set_model, model})

  @doc """
  Changes provider by selecting its first compatible catalog model.

  The selected model is returned and announced, so changing provider never
  leaves a hidden provider preference that disagrees with the model requests
  are actually using.
  """
  @spec set_provider(session :: session(), provider :: String.t()) ::
          {:ok, String.t()} | {:error, :busy | term()}
  def set_provider(session, provider) when is_binary(provider),
    do: GenServer.call(session, {:set_provider, provider})

  @doc "Lists the reasoning-effort choices for the current model."
  @spec reasoning_efforts(session :: session()) :: [String.t()]
  def reasoning_efforts(session), do: GenServer.call(session, :reasoning_efforts)

  @doc """
  Sets the reasoning effort used by future requests.

  `"default"` removes an explicit effort. Like a model change, this is refused
  while work is running and persisted immediately for resume.
  """
  @spec set_reasoning_effort(session :: session(), effort :: String.t()) ::
          {:ok, String.t()} | {:error, :busy | term()}
  def set_reasoning_effort(session, effort) when is_binary(effort),
    do: GenServer.call(session, {:set_reasoning_effort, effort})

  @doc """
  Replaces the session's local tools for future turns.

  Configured MCP tools remain attached: this switches the built-in or
  host-supplied profile without making an unrelated remote server disappear.
  The complete resulting catalog is validated against the current model before
  it is persisted, along with a system notice that makes the new catalog clear
  to models replaying earlier tool calls. Like model changes, a tool-profile
  change is refused while the session is busy so one turn cannot change
  capabilities halfway through.
  """
  @spec set_tools(session :: session(), tools :: [Tool.t()]) ::
          {:ok, [String.t()]} | {:error, :busy | term()}
  def set_tools(session, tools) when is_list(tools),
    do: GenServer.call(session, {:set_tools, tools})

  @doc "Lists every currently available local and MCP tool with its enabled state."
  @spec tool_status(session :: session()) :: [tool_status()]
  def tool_status(session), do: GenServer.call(session, :tool_status)

  @doc """
  The session's configured local tools, as the modules and structs themselves.

  `tool_status/1` answers what a person should be shown; this answers what a
  caller would have to pass back to `set_tools/2` to leave the catalog as it
  found it — the modules and structs themselves, a `delegate` the host passed
  among them. They are different questions because a struct tool has no name
  a front end could rebuild it from: one swapping the tool list reads this
  first, or drops delegation by omission.
  """
  @spec tools(session :: session()) :: [Tool.t()]
  def tools(session), do: GenServer.call(session, :tools)

  @doc """
  Whether this session's host profile would admit `tool`, and if not, why.

  `tool_status/1` answers about the catalog, which is the wrong question for a
  tool that is not in it yet: a front end offering to *switch* to one has to
  know the answer before it asks. Without this, `/elixir` was listed by a
  session whose profile could never grant it, and the only way to find out was
  to run the command and read the refusal.
  """
  @spec tool_decision(session :: session(), tool :: Tool.t()) ::
          :allow | {:deny, Profile.denial()}
  def tool_decision(session, tool), do: GenServer.call(session, {:tool_decision, tool})

  @doc "Enables one or more available tools for future turns while the session is idle."
  @spec enable_tools(session :: session(), names :: [String.t()]) ::
          {:ok, [String.t()]} | {:error, :busy | {:unknown_tools, [String.t()]} | term()}
  def enable_tools(session, names) when is_list(names),
    do: GenServer.call(session, {:set_tool_access, names, true})

  @doc "Disables one or more available tools for future turns while the session is idle."
  @spec disable_tools(session :: session(), names :: [String.t()]) ::
          {:ok, [String.t()]} | {:error, :busy | {:unknown_tools, [String.t()]} | term()}
  def disable_tools(session, names) when is_list(names),
    do: GenServer.call(session, {:set_tool_access, names, false})

  @doc """
  Says something to a session that is already working.

  The text is queued and delivered as a user message at the next turn
  boundary — after the tools of the current turn have run, before the next
  request is built. It is never injected into a request that is already in
  flight, because there is no such thing: the model has the conversation it
  was given, and changing it retroactively is not something a provider
  offers.

  This is the whole reason for running the loop in-process. A wrapped CLI
  takes one prompt on stdin and closes it, so the only way to say something
  else is to end the run and start another one — a new process, a new turn,
  and whatever the agent was in the middle of, abandoned.

  Steering an **idle** session queues the text rather than answering it. The
  queue is drained where the next request is built, so nothing is lost and no
  turn starts on its own: a session that answered a steer unprompted would
  spend tokens nobody asked it to spend. The next `prompt/2` carries it.
  """
  @spec steer(session :: session(), text :: String.t()) :: :ok
  def steer(session, text) when is_binary(text), do: GenServer.call(session, {:steer, text})

  @doc "Revokes a matching steer only while it is still waiting for the next request."
  @spec revoke_steer(session :: session(), text :: String.t()) :: :ok | {:error, :already_sent}
  def revoke_steer(session, text) when is_binary(text),
    do: GenServer.call(session, {:revoke_steer, text})

  @doc "Queues a fresh prompt after current work; starts immediately when idle."
  @spec follow_up(session(), String.t()) :: :ok | {:error, term()}
  def follow_up(session, text) when is_binary(text),
    do: GenServer.call(session, {:follow_up, text}, :infinity)

  @doc """
  Answers a tool call that a hook parked.

  A `before_tool_call` hook that returns `:pending` stops the call where it is
  and puts the decision in somebody else's hands — a person looking at an
  approval card, a service that takes a second to answer. This is how the
  answer gets back: `:allow`, `{:deny, reason}` or `{:rewrite, args}`, exactly
  the decisions the hook itself could have made.

  Returns `{:error, :unknown_call}` for a call that is not waiting — one
  already answered, timed out, or never parked. Saying so matters: a host that
  got no error would believe it had approved something it had not.
  """
  @spec resolve_tool(session :: session(), call_id :: String.t(), decision :: Hooks.decision()) ::
          :ok | {:error, :unknown_call}
  def resolve_tool(session, call_id, decision) when is_binary(call_id),
    do: GenServer.call(session, {:resolve, call_id, {:decision, decision}})

  @doc """
  Answers a question a tool asked.

  The counterpart to `resolve_tool/3` for `Lemieux.Tools.AskUser`: the text
  becomes that tool's result, and the model reads it like any other.
  """
  @spec answer(session :: session(), call_id :: String.t(), text :: String.t() | map()) ::
          :ok | {:error, :unknown_call | :invalid_answer}
  def answer(session, call_id, text) when is_binary(call_id) and is_binary(text),
    do: GenServer.call(session, {:resolve, call_id, {:answer, text}})

  def answer(session, call_id, %{} = answer) when is_binary(call_id) do
    Entry.new(:approval, %{"answer" => answer})
    GenServer.call(session, {:resolve, call_id, {:answer, answer}})
  rescue
    ArgumentError -> {:error, :invalid_answer}
  end

  @doc """
  Parks the calling process until somebody answers, and returns their answer.

  Called from inside a running tool — never from a host — which is why it
  blocks: the caller is the task running that one call, and stopping it is the
  whole point. The session is not blocked, and goes on answering everything
  else.

  `kind` is `:approval` or `:question`; `payload` is what the waiting party is
  shown. `:timeout_reply` optionally supplies a typed timeout result to the
  parked tool. No result is interpreted as user authorization by this seam.
  """
  @spec park(session :: session(), call_id :: String.t(), kind :: atom(), payload :: term()) ::
          term()
  @spec park(
          session :: session(),
          call_id :: String.t(),
          kind :: atom(),
          payload :: term(),
          opts :: keyword()
        ) :: term()
  def park(session, call_id, kind, payload, opts \\ []),
    do: GenServer.call(session, {:park, call_id, kind, payload, opts}, :infinity)

  @doc """
  Stops what the session is doing, leaving it idle and ready for another
  prompt.

  Kills the in-flight provider request and any tools still running, writes a
  `:cancelled` entry, and emits `{:finished, :cancelled}`. The transcript
  keeps everything that happened up to that point, which is what makes the
  session resumable rather than merely stopped.

  The entry matters as much as the killing: a turn that simply stopped
  talking is indistinguishable from a provider that hung up, and a person
  reading the transcript later deserves to know which one it was.

  Cancelling an idle session does nothing and says so by returning `:ok`.
  """
  @spec cancel(session :: session(), reason :: atom()) :: :ok
  def cancel(session, reason \\ :cancelled) when is_atom(reason),
    do: GenServer.call(session, {:cancel, reason})

  @doc """
  Sends the request that just failed again, keeping everything before it.

  A provider failure ends the turn with an `:error` entry and leaves the
  session idle, which is honest and also where a person's afternoon of tool
  results sat behind one gateway hiccup with no way back but a new prompt.
  This is the way back: the next request is built from the transcript as
  it stands — the tool results already recorded, the error entry left in
  place as history — and the model answers the request again. Whatever it had
  said before the failure is on the transcript as a partial entry, for the
  record, and is not sent: continuing someone's half-sentence as though it
  were a finished answer is what a provider calls a prefill, and one refuses
  it outright when the model was thinking.

  Only a turn that ended in a provider failure can be retried. A turn that
  stopped at its turn budget, or one that was cancelled, was not cut off by
  anything a retry would change. Returns `{:error, :busy}` while a turn is
  running and `{:error, :nothing_to_retry}` otherwise.
  """
  @spec retry(session :: session()) :: :ok | {:error, :busy | :nothing_to_retry}
  def retry(session), do: GenServer.call(session, :retry)

  @doc """
  Returns the session's id, status and in-memory transcript.

  `timeout` exists for one caller that cannot afford to wait: a coordinator
  tidying up after a child that has already missed its cancellation grace has,
  by definition, a session that may never answer, and blocking there would
  turn one wedged child into a wedged fan-out. Everything else wants the
  default.
  """
  @spec snapshot(session :: session(), timeout :: timeout()) :: snapshot()
  def snapshot(session, timeout \\ 5_000), do: GenServer.call(session, :snapshot, timeout)

  @doc """
  What a front end draws from, without the transcript.

  `snapshot/1` copies every entry — every request snapshot, every file a tool
  read — out of the session on each call, and a status line that asked for it
  after every event was copying the whole session to learn its model name.
  This answers the same questions a screen asks, plus the ones a snapshot
  cannot: how many requests have been made against `max_requests`, whether
  startup MCP connections have settled, and whether the context window is
  known. See `t:info/0`.
  """
  @spec info(session :: session(), timeout :: timeout()) :: info()
  def info(session, timeout \\ 5_000), do: GenServer.call(session, :info, timeout)

  @doc """
  Sends a prompt and waits for the work it starts to finish.

  The call an embedder usually wants: `prompt/2` returns as soon as a turn has
  started and leaves the rest to a subscriber, which is the right shape for a
  screen and too much ceremony for a job that wants an answer. This subscribes
  a private collector before prompting, so nothing is missed and the caller's
  mailbox receives nothing, and returns when `{:finished, _}` arrives:

    * `:text` — the last assistant answer's text, `""` when there was none;
    * `:stop_reason` — what `{:finished, _}` carried;
    * `:error` — the `{:error, reason}` the turn ended on, or `nil`;
    * `:usage` — the prompt's own usage, summed over its entries;
    * `:entries` — every entry the prompt wrote, oldest first.

  ## Options

    * `:timeout` — how long to wait, `:infinity` by default: a session is
      bounded by its own budgets, and an arbitrary clock here would abandon
      work a model was legitimately doing. On timeout the session keeps
      working and `{:error, :timeout}` is returned; `cancel/1` stops it.
    * `:on_event` — a one-argument function called in the caller's process
      with every event, in order, as it arrives.

  `{:error, :busy}` and the hook refusals are `prompt/2`'s. A session that goes
  down before the prompt finishes — or was already gone — answers
  `{:error, {:session_down, reason}}`, `reason` being its exit reason; the
  session is monitored for the whole wait, so this never waits forever on one
  that has crashed.
  """
  @spec await(session :: session(), text :: String.t(), opts :: keyword()) ::
          {:ok, Await.result()} | {:error, {:session_down, term()} | :timeout | term()}
  def await(session, text, opts \\ []) when is_binary(text) and is_list(opts),
    do: Await.run(session, text, opts)

  @doc "Returns the effective executable catalog to trusted host extensions; never serialize executors."
  @spec catalog(session :: session()) :: [Tool.t()]
  def catalog(session), do: GenServer.call(session, :tool_catalog)

  @doc "Reads the newest opaque extension checkpoint from the authoritative transcript."
  @spec document(session :: session(), namespace :: String.t()) :: {:ok, map()} | {:error, term()}
  def document(session, namespace) when is_binary(namespace),
    do: GenServer.call(session, {:document, namespace})

  @doc """
  Commits a bounded JSON document only if its revision still matches.

  The durable append happens before acknowledgement. Callers compute changes
  outside the session; no extension callback runs inside its GenServer. A stale
  writer receives the current revision and must reconsider its mutation. These
  records survive compaction, resume and fork, but their document values confer
  no runtime authority. A paid extension may pass `usage:` with model, token
  counts and known or unknown cost. That usage is recorded once even if the
  document revision conflicts, contributes to session spend and emits
  `{:usage, usage}`. It is excluded from context-window position.
  """
  @spec put_document(
          session :: session(),
          namespace :: String.t(),
          revision :: non_neg_integer(),
          value :: map(),
          opts :: keyword()
        ) :: {:ok, map()} | {:error, term()}
  def put_document(session, namespace, revision, value, opts \\ [])
      when is_integer(revision) and revision >= 0 and is_list(opts) do
    usage = Keyword.get(opts, :usage)

    with :ok <- Document.validate(namespace, value, usage),
         do: GenServer.call(session, {:put_document, namespace, revision, value, usage})
  end

  @doc "Returns measured spend and the host's cap for a bounded external operation."
  @spec budget(session :: session()) :: %{spent_usd: number() | nil, max_cost_usd: number() | nil}
  def budget(session), do: GenServer.call(session, :budget)

  @doc false
  @spec delegation_context(session :: session()) :: map()
  def delegation_context(session), do: GenServer.call(session, :delegation_context)

  @doc false
  @spec append_subagent_entry(session :: session(), type :: Entry.type(), payload :: map()) ::
          {:ok, Entry.t()}
  def append_subagent_entry(session, type, payload)
      when type in [:subagent_spawn, :subagent_steer, :subagent_result, :subagent_group_result] and
             is_map(payload) do
    GenServer.call(session, {:append_subagent_entry, type, payload})
  end

  @doc false
  @spec publish_subagent_event(session :: session(), event :: term()) :: :ok
  def publish_subagent_event(session, event) do
    GenServer.cast(session, {:publish_subagent_event, event})
  end

  @doc false
  @spec register_subagent_group(session :: session(), group_id :: String.t(), group :: pid()) ::
          :ok
  def register_subagent_group(session, group_id, group)
      when is_binary(group_id) and is_pid(group) do
    GenServer.call(session, {:register_subagent_group, group_id, group})
  end

  @doc false
  @spec unregister_subagent_group(session :: session(), group_id :: String.t()) :: :ok
  def unregister_subagent_group(session, group_id) when is_binary(group_id) do
    GenServer.call(session, {:unregister_subagent_group, group_id})
  end

  @doc """
  Reports each configured MCP server and how many tools it currently offers.

  An unavailable server remains visible with zero tools. This live status is
  not session configuration and is never written to the transcript. While
  startup connections are still running the answer waits for them to settle,
  so it reports what the servers offer rather than a count of zero for a
  server that is merely slow; `info/1` answers at once, with each server's
  connection state.
  """
  @spec mcp_status(session :: session(), timeout :: timeout()) :: [
          %{
            name: String.t(),
            transport: String.t(),
            tool_count: non_neg_integer(),
            enabled?: boolean(),
            error: String.t() | nil
          }
        ]
  def mcp_status(session, timeout \\ 5_000), do: GenServer.call(session, :mcp_status, timeout)

  @doc """
  The MCP servers this session is connected to: each one's name, client and
  the capabilities it declared.

  This includes servers that offer prompts or resources and no tools, which
  the tool catalog cannot show — a host offering MCP prompts as commands, or
  resources as references, finds them here. It answers at once with what is
  connected, like `info/2`'s `mcp` list: a server still connecting at startup
  is not listed yet, and a disabled one is not listed at all. Capabilities
  are asked of each client from the calling process, so a slow server cannot
  stall the session; a client that has gone away is left out.
  """
  @spec mcp_clients(session :: session(), timeout :: timeout()) :: [
          %{name: String.t(), client: pid(), capabilities: map()}
        ]
  def mcp_clients(session, timeout \\ 5_000) do
    session
    |> GenServer.call(:mcp_clients, timeout)
    |> Enum.flat_map(fn {name, client} ->
      case mcp_capabilities(client) do
        {:ok, capabilities} -> [%{name: name, client: client, capabilities: capabilities}]
        :gone -> []
      end
    end)
  end

  @doc """
  The resources every connected server that declared them offers, each
  named with its server — for a host offering them as `@` references.

  Asked of the servers from the calling process, like `mcp_clients/2`. A
  server that fails to list is left out rather than failing the whole list;
  `info/2` still says how its connection stands.
  """
  @spec mcp_resources(session :: session(), timeout :: timeout()) :: [
          %{server: String.t(), uri: String.t(), name: String.t() | nil, resource: map()}
        ]
  def mcp_resources(session, timeout \\ 5_000) do
    session
    |> mcp_clients(timeout)
    |> Enum.filter(&Map.has_key?(&1.capabilities, "resources"))
    |> Enum.flat_map(&server_resources/1)
  end

  defp server_resources(%{name: server, client: client}) do
    case MCP.list_resources(client) do
      {:ok, resources} ->
        Enum.map(resources, fn resource ->
          %{server: server, uri: resource["uri"], name: resource["name"], resource: resource}
        end)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Reads one resource from a connected server, as text.

  Binary contents are described rather than decoded; see
  `Lemieux.MCP.resource/2`. `{:error, :unknown_server}` when no connected
  server has that name.
  """
  @spec mcp_resource(session :: session(), server :: String.t(), uri :: String.t()) ::
          {:ok, String.t()} | {:error, :unknown_server | String.t()}
  def mcp_resource(session, server, uri) when is_binary(server) and is_binary(uri) do
    case Enum.find(mcp_clients(session), &(&1.name == server)) do
      %{client: client} -> MCP.resource(client, uri)
      nil -> {:error, :unknown_server}
    end
  end

  # A client whose server died between the session's answer and this question
  # has nothing to offer; it is not an error for the caller to handle.
  defp mcp_capabilities(client) do
    {:ok, MCP.Client.info(client).capabilities || %{}}
  catch
    :exit, _reason -> :gone
  end

  @doc "Enables or disables a configured MCP server for this session only."
  @spec set_mcp_enabled(session :: session(), name :: String.t(), enabled? :: boolean()) ::
          :ok | {:error, :busy | :unknown_server}
  def set_mcp_enabled(session, name, enabled?) when is_binary(name) and is_boolean(enabled?),
    do: GenServer.call(session, {:set_mcp_enabled, name, enabled?}, :infinity)

  @doc """
  Adds or replaces MCP server configurations, matching them by server name.

  The session must be idle so its tool set cannot change underneath work that
  is already in flight.
  """
  @spec add_mcp_servers(session :: session(), servers :: [map()]) :: :ok | {:error, :busy}
  def add_mcp_servers(session, servers) when is_list(servers),
    do: GenServer.call(session, {:add_mcp_servers, servers}, :infinity)

  @doc """
  Removes one configured MCP server by name while the session is idle.
  """
  @spec remove_mcp_server(session :: session(), name :: String.t()) ::
          :ok | {:error, :busy | :unknown_server}
  def remove_mcp_server(session, name) when is_binary(name),
    do: GenServer.call(session, {:remove_mcp_server, name}, :infinity)

  @doc """
  Reconnects one configured MCP server, or all of them, and refreshes the
  tools they offer.

  A reconnect is something a person asked for, so a server whose OAuth flow
  needs a browser sign-in may start one here (`interactive_auth: true` over
  the host's connect options). Startup never does: a server that needs
  consent at startup settles as `:needs_auth`, and this is how it is signed
  in to afterwards.
  """
  @spec reconnect_mcp(session :: session(), name :: String.t() | :all) ::
          :ok | {:error, :busy | :unknown_server | :server_disabled}
  def reconnect_mcp(session, name) when is_binary(name) or name == :all,
    do: GenServer.call(session, {:reconnect_mcp, name}, :infinity)

  @doc """
  Summarises the elder part of the conversation now, whatever the position.

  What a `/compact` command calls. Blocks for the length of a model request,
  which is why it takes a timeout, and returns what was cut so a caller can say
  so. `{:error, :nothing_to_do}` for a conversation too short to be worth a
  round trip; `{:error, :busy}` while the session is working.

  Compaction also happens on its own at `:compact_at`; this is for the person
  who can see it coming and would rather it happened between tasks than in the
  middle of one.
  """
  @spec compact(session :: session(), timeout :: timeout()) ::
          {:ok, map()} | {:error, :busy | :nothing_to_do | String.t()}
  def compact(session, timeout \\ :timer.minutes(2)),
    do: GenServer.call(session, :compact, timeout)

  @doc """
  Queues a short lived host signal for the next prepared request.

  An Ixway route or another host may call this while the model is running.
  The signal names the exact request model, a future UTC `DateTime` under
  `:expires_at`, and `:reason` (`:cost` or `:logical`). An optional positive
  `:keep_recent_tokens` overrides the retained-tail target for one cut. The
  optional `:scope` must equal the final request's
  `context["compaction_scope"]`, which a host hook can set from its resolved
  route. This prevents an old route's advice from following an alias to a new
  route. The
  signal never interrupts an in-flight request and is discarded after a
  dispatch, a model mismatch, or expiry.
  """
  @spec advise_compaction(session :: session(), advice :: map()) ::
          :ok | {:error, :invalid_advice}
  def advise_compaction(session, advice) when is_map(advice),
    do: GenServer.call(session, {:advise_compaction, advice})

  @doc """
  Stops sending the conversation so far, without ending the session.

  A host operation that makes the next prompt start from the system prompt
  and nothing else, in the same session, with the same model, tools and
  transcript file.

  This is compaction with the summary left out, and it is the same mechanism
  for the same reason — it **appends**. A `:compaction` entry whose cut point
  is the last entry on the transcript makes `Lemieux.Compaction.applied/1`
  return nothing before it, and a `nil` summary means nothing stands in for
  what was dropped. Everything said so far is still on disk, so `lmx log`, a
  fork and a replay all still show the whole session; only what is *sent* is
  reset. Deleting the entries instead would make "clear the context" and
  "destroy the record of this session" the same button.

  Unlike `compact/2` this costs no request, so it does not take a timeout.
  `{:error, :nothing_to_do}` when nothing is being sent yet; `{:error, :busy}`
  while the session is working — clearing mid-turn would cut between a tool
  call and its result, which is the split `Lemieux.Compaction` exists to
  prevent.
  """
  @spec clear(session :: session()) ::
          {:ok, %{entries: non_neg_integer()}} | {:error, :busy | :nothing_to_do}
  def clear(session), do: GenServer.call(session, :clear)

  @impl GenServer
  def init(opts), do: Boot.boot(opts)

  @impl GenServer
  def handle_continue(continuation, state), do: Boot.continue_with(continuation, state)

  @impl GenServer
  def handle_call(request, from, state), do: Calls.call(request, from, state)

  @impl GenServer
  def handle_cast(request, state), do: Calls.cast(request, state)

  @impl GenServer
  def handle_info(message, state), do: Mailbox.message(message, state)

  @impl GenServer
  def terminate(reason, state) do
    Hooks.session_end(state.hooks, reason, Prompts.hook_context(state))
    :ok
  after
    OpenTelemetry.drop_session(state.id)
    # The transcript's claim (`Lemieux.Store.lock/2`), released last so no
    # other writer can start before `session_end` has run. Never released
    # before, every exit left `<id>.lock` behind for the next claim to judge.
    Lemieux.Store.unlock(state.store, state.id, state.store_lock)
  end
end

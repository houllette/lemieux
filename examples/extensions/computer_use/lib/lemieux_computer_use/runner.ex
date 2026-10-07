defmodule LemieuxComputerUse.Runner do
  @moduledoc """
  A bounded observe/classify/act loop. DONE is only a model claim until a
  host-supplied verifier checks a fresh observation. A rejected completion can
  receive bounded feedback for correction; it never replays a previous action.
  Every browser input and discovery request uses the current Lemieux hooks.
  No action is replayed on
  resume, and only stale observations known to precede input may be retried.

  `:on_event` receives ordered JSON receipts (including intent before input),
  allowing a host to retain evidence even if it cancels the outer tool. The
  standalone command can write these to a private JSONL journal. No raw
  System One requests, API keys or browser handles are evidence.

  Each step's choices come from `:classify`, a host's callback, or else from
  the System One provider in `:systemone` (`provider:` or `client:`, and
  `timeout_ms:`; see `LemieuxComputerUse.SystemOne`). The classifier is
  settled before discovery or the browser starts: a run with neither stops
  with "no System One provider is configured" instead of opening a page it
  cannot act on.
  """
  alias LemieuxComputerUse.{Action, Decision, Discovery, Policy, Search, SystemOne, Text}
  alias Lemieux.Tools
  alias Lemieux.Tools.WebSearch

  @spec run(args :: map(), opts :: keyword(), context :: map()) :: {:ok | :error, map()}
  def run(args, opts, context \\ %{}) do
    with {:ok, opts} <- LemieuxComputerUse.validate(opts),
         :ok <- input(args),
         {:ok, classify} <- classifier(opts) do
      opts = Keyword.put(opts, :classify, classify)

      context =
        Map.merge(
          %{
            cwd: File.cwd!(),
            environment: Lemieux.Environment.local(),
            tool_output_bytes: 120_000,
            hooks: []
          },
          context
        )

      # The temporary supervisor is linked to this invocation. Cancellation
      # kills its worker, which Wallaby monitors to reclaim the browser.
      {:ok, supervisor} = Task.Supervisor.start_link()

      try do
        task = Task.Supervisor.async_nolink(supervisor, fn -> perform(args, opts, context) end)

        case Task.yield(task, Keyword.get(opts, :timeout_ms, 90_000)) ||
               Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> failure("timeout_or_worker_failure")
        end
      after
        Supervisor.stop(supervisor)
      end
    else
      {:error, reason} -> failure(reason)
    end
  end

  defp input(%{"goal" => goal} = args) when is_binary(goal) and byte_size(goal) in 1..4000 do
    if (is_binary(args["url"]) and byte_size(args["url"]) in 1..2048) or
         (is_binary(args["query"]) and byte_size(args["query"]) in 1..400),
       do: :ok,
       else: {:error, "Supply a starting url or search query"}
  end

  defp input(_), do: {:error, "Supply a nonempty goal of at most 4000 bytes"}

  # One SDK client per run, built before anything is fetched or opened.
  defp classifier(opts) do
    case Keyword.fetch(opts, :classify) do
      {:ok, classify} ->
        {:ok, classify}

      :error ->
        systemone = Keyword.get(opts, :systemone, [])

        with {:ok, client} <- SystemOne.client(systemone) do
          options = [client: client] ++ Keyword.take(systemone, [:timeout_ms])
          {:ok, &SystemOne.evaluate(&1, options)}
        end
    end
  end

  defp perform(args, opts, context) do
    started = System.monotonic_time(:millisecond)

    with {:ok, url} <- seed(args, opts, context),
         :ok <- Policy.check(url, opts) do
      discovery = Discovery.crawl(url, opts, context)
      emit(opts, %{"event" => "discovery", "requests" => discovery["requests"]})
      driver = Keyword.get(opts, :driver, LemieuxComputerUse.Wallaby)

      case open(driver, url, opts, context) do
        {:ok, session} ->
          try do
            state = %{
              goal: args["goal"],
              opts: opts,
              context: context,
              driver: driver,
              session: session,
              discovery: discovery,
              history: [],
              decisions: [],
              text_calls: [],
              verification_feedback: [],
              started: started,
              attempts: 0
            }

            loop(state)
          after
            driver.close(session)
          end

        {:error, _} ->
          failure("browser_open_failed")
      end
    else
      {:error, reason} -> failure(reason)
    end
  end

  defp open(driver, url, opts, context) do
    ref = make_ref()
    tool = %LemieuxComputerUse.Open{url: url, driver: driver, opts: opts, reply_ref: ref}

    call = %{
      id: "#{Map.get(context, :call_id, "browser")}-open",
      name: "computer_use_open",
      arguments: %{"url" => url}
    }

    emit(opts, %{"event" => "open_intent", "url" => url})
    receipt = Tools.run([tool], context.hooks, call, context)
    emit(opts, %{"event" => "open_result", "url" => url, "outcome" => to_string(receipt.outcome)})

    receive do
      {^ref, session} -> {:ok, session}
    after
      0 -> {:error, :open_failed}
    end
  end

  defp seed(%{"url" => url}, _opts, _context) when is_binary(url), do: {:ok, url}

  defp seed(%{"query" => query}, opts, context) do
    tool =
      WebSearch.new(
        backend: Keyword.get(opts, :search, {Search, nil}),
        max_results: 5,
        max_cost_usd: Keyword.get(opts, :search_cost_usd)
      )

    receipt =
      Tools.run(
        [tool],
        context.hooks,
        %{id: "browser-search", name: "web_search", arguments: %{"query" => query}},
        context
      )

    seed_result(receipt, opts)
  end

  defp seed_result(%{error?: true, output: message}, _opts), do: {:error, message}

  defp seed_result(receipt, opts) do
    rows = get_in(receipt, [:structured_content, "results"]) || []

    case Enum.find(rows, &(Policy.check(&1["url"], opts) == :ok)) do
      nil -> {:error, "Search produced no permitted starting URL"}
      row -> {:ok, row["url"]}
    end
  end

  defp loop(state) do
    if state.attempts >= Keyword.get(state.opts, :max_steps, 30) do
      finish(state, "budget_exhausted", nil, false)
    else
      observe_and_choose(state)
    end
  end

  defp observe_and_choose(state) do
    with {:ok, page} <- state.driver.observe(state.session),
         :ok <- Policy.check(page["url"], state.opts) do
      request =
        Decision.request(
          page,
          state.goal,
          state.history,
          state.discovery["pages"],
          state.verification_feedback
        )

      classify = Keyword.fetch!(state.opts, :classify)
      {micros, response} = :timer.tc(fn -> classify.(request) end)
      state = %{state | attempts: state.attempts + 1}

      case response do
        {:ok, response} when is_map(response) ->
          choose(state, page, request, response, div(micros, 1000))

        {:error, reason} ->
          finish(state, "classifier_failed", page, false, diagnostic(reason))

        _ ->
          finish(state, "classifier_failed", page, false)
      end
    else
      {:error, _} -> finish(state, "observation_or_navigation_refused", nil, false)
    end
  end

  defp choose(state, page, request, response, latency) do
    case Decision.decode(request, response, page, Keyword.get(state.opts, :min_confidence, 0.0)) do
      {:ok, action, confidence} ->
        evidence =
          Map.merge(confidence, %{
            "event" => "decision",
            "operation" => action["operation"],
            "target" => action["id"],
            "model" => response["model"],
            "usage" => response["usage"],
            "latency_ms" => latency
          })

        emit(state.opts, evidence)
        state = %{state | decisions: state.decisions ++ [evidence]}
        dispatch(state, page, action)

      {:error, reason} ->
        finish(state, to_string(reason), page, false)
    end
  end

  defp dispatch(state, page, %{"operation" => "DONE"}) do
    case Keyword.get(state.opts, :verify) do
      nil ->
        finish(state, "done_unverified", page, false)

      verify ->
        with {:ok, fresh} <- state.driver.observe(state.session),
             :ok <- Policy.check(fresh["url"], state.opts) do
          if verify.(fresh) == true,
            do: finish(state, "completed", fresh, true),
            else: verification_failed(state, fresh)
        else
          _ -> finish(state, "verification_failed", page, false)
        end
    end
  end

  defp dispatch(state, page, %{"operation" => "BLOCKED"}),
    do: finish(state, "blocked", page, false)

  defp dispatch(state, page, action) do
    case text(state, page, action) do
      {:ok, value, usage} -> act(state, page, action, value, usage)
      {:error, reason} -> finish(state, "text_generation_failed", page, false, diagnostic(reason))
    end
  end

  defp verification_failed(state, page) do
    event = %{"event" => "verification_result", "verified" => false, "url" => page["url"]}
    emit(state.opts, event)
    retries = length(state.verification_feedback)
    state = %{state | verification_feedback: state.verification_feedback ++ [event]}

    # Retry only a completion claim against a fresh, permitted observation.
    # The ordinary classification budget also bounds these correction attempts;
    # native input errors and policy refusals remain terminal.
    if retries < Keyword.get(state.opts, :max_verification_retries, 1),
      do: loop(state),
      else: finish(state, "verification_failed", page, false)
  end

  defp text(state, page, %{"operation" => "TYPE_TEXT"} = action) do
    helper = Keyword.get(state.opts, :text, &Text.generate/4)
    helper.(state.goal, action, page, state.opts)
  end

  defp text(_state, _page, _action), do: {:ok, nil, nil}

  defp act(state, page, action, value, usage) do
    args = Action.arguments(page, action, value)
    # Values are intentionally absent from retained receipts. They remain in
    # the hook arguments so host policy can inspect the proposed input.
    emit(state.opts, Map.merge(Map.delete(args, "text"), %{"event" => "action_intent"}))

    tool = %Action{
      driver: state.driver,
      session: state.session,
      page: page,
      action: action,
      text: value,
      opts: state.opts
    }

    call = %{
      id: "#{Map.get(state.context, :call_id, "browser")}-#{state.attempts}",
      name: "computer_use_action",
      arguments: args
    }

    receipt = Tools.run([tool], state.context.hooks, call, state.context)

    evidence =
      Map.merge(Map.delete(args, "text"), %{
        "event" => "action_result",
        "observation" =>
          :crypto.hash(:sha256, JSON.encode!(Map.take(page, ~w(url text form_state))))
          |> Base.encode16(case: :lower),
        "outcome" => to_string(receipt.outcome),
        "stale" => get_in(receipt, [:structured_content, "stale"]) == true
      })

    emit(state.opts, evidence)

    state = %{
      state
      | history: state.history ++ [evidence],
        text_calls: state.text_calls ++ if(usage, do: [usage], else: [])
    }

    cond do
      evidence["stale"] ->
        loop(state)

      receipt.error? ->
        finish(state, "action_refused_or_uncertain", page, false)

      action["operation"] != "WAIT" and repeated?(state.history) ->
        finish(state, "repeated_action", page, false)

      true ->
        loop(state)
    end
  end

  defp repeated?(history) when length(history) < 4, do: false

  defp repeated?(history) do
    history
    |> Enum.take(-4)
    |> Enum.map(&Map.take(&1, ~w(url operation target observation)))
    |> Enum.uniq()
    |> length() == 1
  end

  defp finish(state, status, page, verified, reason \\ nil) do
    report = %{
      "status" => status,
      "reason" => reason,
      "verified" => verified,
      "url" => page && page["url"],
      "steps" => length(state.history),
      "elapsed_ms" => System.monotonic_time(:millisecond) - state.started,
      "decisions" => state.decisions,
      "classifier_attempts" => state.attempts,
      "verification_feedback" => state.verification_feedback,
      "actions" => state.history,
      "text_calls" => state.text_calls,
      "discovery" => state.discovery["requests"],
      "classifier_cost_usd" => nil
    }

    emit(state.opts, %{"event" => "finished", "status" => status, "verified" => verified})
    {if(status in ["completed", "done_unverified"], do: :ok, else: :error), report}
  end

  defp emit(opts, event), do: Keyword.get(opts, :on_event, fn _ -> :ok end).(event)

  # Callbacks may return secrets in arbitrary error text. Only our fixed
  # diagnostics and a numeric HTTP status are safe for retained evidence.
  defp diagnostic(reason) when is_binary(reason) do
    known = [
      "no System One provider is configured",
      "System One provider is unusable",
      "System One client is invalid",
      "System One request is invalid",
      "System One returned an invalid response",
      "System One transport failed",
      "TYPE_TEXT requires a configured text_model through ReqLLM",
      "Text model did not return a valid field value",
      "Text model request failed"
    ]

    if reason in known or Regex.match?(~r/^System One returned HTTP [1-5][0-9]{2}$/, reason),
      do: reason,
      else: nil
  end

  defp diagnostic(_), do: nil

  defp failure(reason),
    do: {:error, %{"status" => "failed", "reason" => reason, "verified" => false}}
end

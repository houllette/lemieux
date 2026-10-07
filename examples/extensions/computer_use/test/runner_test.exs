defmodule LemieuxComputerUse.RunnerTest do
  use ExUnit.Case, async: true
  alias LemieuxComputerUse.Runner

  defmodule Driver do
    @behaviour LemieuxComputerUse.Driver
    def open(_url, opts) do
      {:ok, pid} =
        Agent.start_link(fn -> %{owner: opts[:test_owner], calls: 0, stale: opts[:stale]} end)

      {:ok, pid}
    end

    def observe(pid) do
      count = Agent.get(pid, & &1.calls)

      {:ok,
       %{
         "url" => "https://example.com/",
         "text" => if(count > 0, do: "Finished", else: "Start"),
         "actions" => [%{"id" => "1", "operation" => "CLICK", "label" => "Start"}]
       }}
    end

    def act(pid, _page, _action, _text) do
      Agent.get_and_update(pid, fn state ->
        send(state.owner, {:input, state.calls})
        result = if state.stale == true and state.calls == 0, do: {:error, :stale}, else: :ok
        {result, %{state | calls: state.calls + 1}}
      end)
    end

    def close(pid) do
      send(Agent.get(pid, & &1.owner), :closed)
      Agent.stop(pid)
    end
  end

  test "fresh observations, verified completion and cleanup form one connected loop" do
    assert {:ok, report} = Runner.run(input(), opts() ++ [verify: &(&1["text"] == "Finished")])
    assert report["verified"]
    assert report["status"] == "completed"
    assert report["steps"] == 1
    assert length(report["decisions"]) == 2
    assert_receive {:input, 0}
    assert_receive :closed
  end

  test "DONE alone cannot claim verified success" do
    assert {:ok, %{"status" => "done_unverified", "verified" => false}} =
             Runner.run(input(), opts())

    assert {:error, %{"status" => "verification_failed"}} =
             Runner.run(input(), opts() ++ [verify: fn _ -> false end])
  end

  test "a failed completion check gives one bounded correction with fresh state" do
    owner = self()

    classify = fn request ->
      feedback = request["state"]["verification_feedback"]
      send(owner, {:feedback, feedback})

      if request["state"]["page"]["text"] == "Start" and feedback == [] do
        result = classify(request)

        answers =
          put_in(result |> elem(1), ["answers", "operation"], %{
            "choice" => "DONE",
            "confidence" => 1.0,
            "probabilities" =>
              Map.new(request["questions"]["operation"]["criteria"], fn {id, _} ->
                {id, if(id == "DONE", do: 1.0, else: 0.0)}
              end)
          })

        {:ok, answers}
      else
        classify(request)
      end
    end

    options =
      opts()
      |> Keyword.put(:classify, classify)
      |> Keyword.put(:verify, &(&1["text"] == "Finished"))

    assert {:ok, report} = Runner.run(input(), options)
    assert report["verified"]
    assert report["classifier_attempts"] == 3
    assert [%{"verified" => false}] = report["verification_feedback"]
    assert_receive {:feedback, []}
    assert_receive {:feedback, [%{"verified" => false}]}
    assert_receive {:input, 0}
  end

  test "repeated false completion claims stop without replaying input" do
    owner = self()

    options =
      opts() ++
        [
          verify: fn _ ->
            send(owner, :verification)
            false
          end
        ]

    assert {:error, report} = Runner.run(input(), options)
    assert report["status"] == "verification_failed"
    assert report["classifier_attempts"] == 3
    assert length(report["verification_feedback"]) == 2
    assert_receive {:input, 0}
    refute_receive {:input, 1}
    assert_receive :verification
    assert_receive :verification
    refute_receive :verification
  end

  test "completion correction can be disabled and shares the classification budget" do
    for {extra, status, attempts} <- [
          {[max_verification_retries: 0], "verification_failed", 2},
          {[max_steps: 2], "budget_exhausted", 2}
        ] do
      options = opts() ++ [verify: fn _ -> false end] ++ extra
      assert {:error, report} = Runner.run(input(), options)
      assert report["status"] == status
      assert report["classifier_attempts"] == attempts
      assert_receive {:input, 0}
      refute_receive {:input, 1}
    end

    for limit <- [-1, 4] do
      assert {:error, %{"status" => "failed"}} =
               Runner.run(input(), opts() ++ [max_verification_retries: limit])

      refute_receive {:input, _}
    end
  end

  test "the effective host hook can deny an inner action before input" do
    hook = fn call, _ ->
      if call.name == "computer_use_action", do: {:deny, "no"}, else: :allow
    end

    assert {:error, report} = Runner.run(input(), opts(), %{hooks: [before_tool_call: hook]})
    assert report["status"] == "action_refused_or_uncertain"
    assert [%{"outcome" => "denied"}] = report["actions"]
    refute_receive {:input, _}
    assert_receive :closed
  end

  test "a hook rewrite cannot silently execute the old action" do
    hook = fn call, _ ->
      if call.name == "computer_use_action",
        do: {:rewrite, Map.put(call.arguments, "target", "invented")},
        else: :allow
    end

    assert {:error, report} = Runner.run(input(), opts(), %{hooks: [before_tool_call: hook]})
    assert report["status"] == "action_refused_or_uncertain"
    refute_receive {:input, _}
  end

  test "budgets and malformed classifier choices stop the loop" do
    assert {:error, %{"status" => "budget_exhausted"}} =
             Runner.run(input(), opts() ++ [max_steps: 1])

    options = Keyword.put(opts(), :classify, fn _ -> {:ok, %{"answers" => %{}}} end)

    assert {:error,
            %{"status" => "invalid_choice", "classifier_attempts" => 1, "decisions" => []}} =
             Runner.run(input(), options)
  end

  test "private addresses are refused before browser startup" do
    options = Keyword.put(opts(), :resolver, fn _ -> {:ok, [{10, 0, 0, 1}]} end)

    assert {:error, %{"reason" => "Navigation address is not allowed"}} =
             Runner.run(input(), options)

    refute_receive :closed
  end

  test "initial navigation is governed before the driver starts" do
    hook = fn _, _ -> {:deny, "no browser"} end

    assert {:error, %{"reason" => "browser_open_failed"}} =
             Runner.run(input(), opts(), %{hooks: [before_tool_call: hook]})

    refute_receive :closed
    refute_receive {:input, _}
  end

  test "a malformed classifier envelope fails without input and closes the session" do
    options = Keyword.put(opts(), :classify, fn _ -> {:ok, nil} end)
    assert {:error, %{"status" => "classifier_failed"}} = Runner.run(input(), options)
    refute_receive {:input, _}
    assert_receive :closed
  end

  test "with no classifier the run stops before discovery or the browser, without falling back" do
    options = Keyword.delete(opts(), :classify)

    assert {:error, %{"reason" => "no System One provider is configured"}} =
             Runner.run(input(), options)

    unusable = %{
      name: "local",
      type: :endpoint,
      base_url: "http://127.0.0.1:11434",
      api_key: nil,
      api_key_header: nil,
      headers: %{},
      model: nil
    }

    assert {:error, %{"reason" => "System One provider is unusable"}} =
             Runner.run(input(), Keyword.put(options, :systemone, provider: unusable))

    assert {:error, %{"reason" => ":jev was renamed :systemone" <> _}} =
             Runner.run(input(), Keyword.put(options, :jev, api_key: "test-secret"))

    assert {:error, %{"reason" => reason}} =
             Runner.run(input(), Keyword.put(options, :systemone, api_key: "test-secret"))

    assert reason =~ "provider:"
    refute reason =~ "test-secret"
    refute_receive :closed
  end

  test "a classifier's fixed diagnostic is kept and any other error text is not" do
    for {error, kept} <- [
          {"System One returned HTTP 503", "System One returned HTTP 503"},
          {"System One transport failed", "System One transport failed"},
          {"System One returned HTTP 503: secret body", nil},
          {"provider said test-secret", nil}
        ] do
      options = Keyword.put(opts(), :classify, fn _ -> {:error, error} end)

      assert {:error, %{"status" => "classifier_failed", "reason" => ^kept}} =
               Runner.run(input(), options)

      assert_receive :closed
    end
  end

  test "describe names the classifier and its provider, never its key or address" do
    provider = %{
      name: "local",
      type: :endpoint,
      base_url: "http://127.0.0.1:11434",
      api_key: "test-secret",
      api_key_header: nil,
      headers: %{},
      model: "clef-flash"
    }

    assert {:ok, opts} =
             LemieuxComputerUse.init(
               allowed_hosts: ["example.com"],
               systemone: [provider: provider]
             )

    description = LemieuxComputerUse.describe(opts)
    assert description["classifier"] == "systemone"
    assert description["systemone_provider"] == "local"
    refute inspect(description) =~ "test-secret"
    refute inspect(description) =~ "11434"

    assert {:ok, opts} = LemieuxComputerUse.init(allowed_hosts: ["example.com"])
    refute Map.has_key?(LemieuxComputerUse.describe(opts), "systemone_provider")
  end

  test "harness assembly adds the ordinary tool and final host policy governs its nested actions" do
    assert {:ok, harness} =
             Lemieux.Harness.assemble(Lemieux.Harness.new(), [{LemieuxComputerUse, opts()}])

    assert Enum.any?(harness.tools, &(Lemieux.Tool.name(&1) == "computer_use"))
    refute_receive :closed

    hooks = [
      before_tool_call: fn call, _ ->
        if call.name == "computer_use_action", do: {:deny, "host policy"}, else: :allow
      end
    ]

    receipt =
      Lemieux.Tools.run(
        harness.tools,
        hooks,
        %{id: "outer", name: "computer_use", arguments: input()},
        %{tool_output_bytes: 120_000}
      )

    assert receipt.error?
    assert receipt.structured_content["status"] == "action_refused_or_uncertain"
    refute_receive {:input, _}
    assert_receive :closed
  end

  test "the wall-clock bound kills a stalled classifier and its linked session" do
    owner = self()

    classify = fn _ ->
      send(owner, {:worker, self()})

      receive do
        :never -> {:error, "unreachable"}
      end
    end

    options = opts() |> Keyword.put(:classify, classify) |> Keyword.put(:timeout_ms, 100)
    assert {:error, %{"reason" => "timeout_or_worker_failure"}} = Runner.run(input(), options)
    assert_receive {:worker, pid}
    refute Process.alive?(pid)
    refute_receive {:input, _}
  end

  test "assembly reuses the host's configured search and keeps its request cost" do
    owner = self()

    state =
      Lemieux.WebSearch.Backends.Scripted.new([
        fn query, _opts ->
          send(owner, {:host_search, query})

          {:ok,
           [%Lemieux.WebSearch.Result{title: "Start", url: "https://example.com/", snippet: ""}],
           %{}}
        end
      ])

    backend = {Lemieux.WebSearch.Backends.Scripted, state}
    search = Lemieux.Tools.WebSearch.new(backend: backend, max_cost_usd: 0.005)

    assert {:ok, harness} =
             Lemieux.Harness.assemble(Lemieux.Harness.new(tools: [search]), [
               {LemieuxComputerUse, opts()}
             ])

    browser = Enum.find(harness.tools, &(Lemieux.Tool.name(&1) == "computer_use"))
    assert browser.opts[:search] == backend
    assert browser.opts[:search_cost_usd] == 0.005

    receipt =
      Lemieux.Tools.run(
        harness.tools,
        [
          before_tool_call: fn call, _ ->
            if call.name == "computer_use_open", do: {:deny, "stop before opening"}, else: :allow
          end
        ],
        %{
          id: "outer",
          name: "computer_use",
          arguments: %{"query" => "Find start", "goal" => "Finish"}
        },
        %{tool_output_bytes: 120_000}
      )

    assert receipt.error?
    assert_receive {:host_search, "Find start"}
    refute_receive :closed
  end

  test "nested search preserves the host's failure reason" do
    state =
      Lemieux.WebSearch.Backends.Scripted.new([{:error, "Brave Search rate limit exceeded"}])

    backend = {Lemieux.WebSearch.Backends.Scripted, state}

    assert {:error, report} =
             Runner.run(
               %{"query" => "Find start", "goal" => "Finish"},
               opts() ++ [search: backend]
             )

    assert report["reason"] =~ "Brave Search rate limit exceeded"
    refute_receive :closed
  end

  test "an explicit extension search backend takes precedence over the host's" do
    host_state = Lemieux.WebSearch.Backends.Scripted.new([])
    explicit_state = Lemieux.WebSearch.Backends.Scripted.new([])
    host = {Lemieux.WebSearch.Backends.Scripted, host_state}
    explicit = {Lemieux.WebSearch.Backends.Scripted, explicit_state}
    tool = Lemieux.Tools.WebSearch.new(backend: host, max_cost_usd: 0.005)

    assert {:ok, harness} =
             Lemieux.Harness.assemble(Lemieux.Harness.new(tools: [tool]), [
               {LemieuxComputerUse, opts() ++ [search: explicit, search_cost_usd: 0.002]}
             ])

    browser = Enum.find(harness.tools, &(Lemieux.Tool.name(&1) == "computer_use"))
    assert browser.opts[:search] == explicit
    assert browser.opts[:search_cost_usd] == 0.002
  end

  @tag :tmp_dir
  test "a nested input parks in a real Lemieux session and a denial is durably recorded", %{
    tmp_dir: path
  } do
    runtime = :"computer_use_approval_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    provider =
      Lemieux.Providers.Scripted.new([
        [
          {:tool_call, %{id: "outer", name: "computer_use", arguments: input()}},
          {:done, :tool_calls}
        ],
        [{:text_delta, "Stopped"}, {:done, :stop}]
      ])

    {:ok, harness} =
      Lemieux.Harness.assemble(Lemieux.Harness.new(), [{LemieuxComputerUse, opts()}])

    store = Lemieux.Store.JSONL.new(path)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        store: store,
        model: "test:model",
        subscriber: self(),
        harness: harness,
        hooks: [
          before_tool_call: fn call, _ ->
            if call.name == "computer_use_action", do: :pending, else: :allow
          end
        ]
      )

    id = Lemieux.Session.id(session)
    :ok = Lemieux.Session.prompt(session, "Use the browser")
    assert_receive {:lemieux, ^id, {:tool_approval, parked}}, 2000
    assert parked.id == "outer-1"
    assert parked.name == "computer_use_action"
    refute_receive {:input, _}
    assert :ok = Lemieux.Session.resolve_tool(session, parked.id, {:deny, "Do not click"})
    assert_receive {:lemieux, ^id, {:finished, :stop}}, 2000
    assert_receive :closed
    assert {:ok, entries} = Lemieux.Store.read(store, id)

    assert entries |> Enum.filter(&(&1.type == :approval)) |> Enum.map(& &1.payload["status"]) ==
             ["pending", "denied"]

    result = Enum.find(entries, &(&1.type == :tool_result))
    assert result.payload["error"]
    assert result.payload["output"] =~ "action_refused_or_uncertain"
  end

  defp input, do: %{"url" => "https://example.com/", "goal" => "Finish"}

  defp opts do
    [
      driver: Driver,
      test_owner: self(),
      allowed_hosts: ["example.com"],
      crawl_pages: 0,
      resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
      classify: &classify/1
    ]
  end

  defp classify(request) do
    selected = if request["state"]["page"]["text"] == "Finished", do: "DONE", else: "CLICK"

    answers =
      Map.new(request["questions"], fn {head, q} ->
        chosen = if head == "operation", do: selected, else: "1"

        {head,
         %{
           "choice" => chosen,
           "confidence" => 1.0,
           "probabilities" =>
             Map.new(q["criteria"], fn {id, _} -> {id, if(id == chosen, do: 1.0, else: 0.0)} end)
         }}
      end)

    {:ok, %{"model" => "fixture", "answers" => answers, "usage" => %{"input_tokens" => 1}}}
  end
end

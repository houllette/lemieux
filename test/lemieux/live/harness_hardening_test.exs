defmodule Lemieux.Live.HarnessHardeningTest do
  @moduledoc """
  The 2026-09-17 hardening, against models that did not agree to be scripted.

  Everything in this change has offline tests over `Lemieux.Providers.Scripted`,
  which proves the code does what it was written to do and nothing about
  whether real models produce the shapes it was written for. These three do
  that, and they are the ones worth paying for:

    * **the opportunity reflection** asks a real model for a JSON list over a
      real transcript and records what it named. A scripted double always
      answers in the contract; a real one decides whether the instructions are
      clear enough, which is the question.
    * **the lenient child envelope** runs a real delegation and asserts the
      parent received what each child found, whatever shape it arrived in.
      The strict version discarded 33 of 122 children in the evaluation this
      change came from, so a live run is the only honest check that it stopped.
    * **the stream timeout** is provoked with a one-millisecond transport
      timeout against a real endpoint, which is the one way to get the
      classification path the evaluation lane now keys on without waiting for
      a bad day.

  `@tag :live` and excluded by default; a provider with no key skips. Models
  are named by their family and effort so a rerun on a later release is a one
  line change and the retained result says which release it was.
  """

  use ExUnit.Case, async: true

  alias Lemieux.CLI.Feedback
  alias Lemieux.Feedback.Store, as: FeedbackStore
  alias Lemieux.Feedback.Store.JSONL, as: FeedbackJSONL
  alias Lemieux.Providers.ReqLLM, as: ReqLLMProvider
  alias Lemieux.Reflection
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Request
  alias Lemieux.Subagent.Task, as: SubagentTask
  alias Lemieux.Tools

  @moduletag :live
  # Even when chosen by `path:LINE`; see `LemieuxTest.Spend.skip/0`.
  @moduletag skip: LemieuxTest.Spend.skip()
  @moduletag :tmp_dir
  @moduletag timeout: :timer.minutes(12)

  # One row per live configuration. Latest releases, at efforts that differ,
  # because effort changes how much of the instruction a model actually reads.
  @configurations [
    %{name: "gpt-5.6 (medium)", model: "openai:gpt-5.6", effort: "medium", key: "OPENAI_API_KEY"},
    %{
      name: "gpt-5.6-luna (low)",
      model: "openai:gpt-5.6-luna",
      effort: "low",
      key: "OPENAI_API_KEY"
    },
    %{
      name: "glm-5.3 (default)",
      model: "zai_coding_plan:glm-5.3",
      effort: "default",
      key: "ZAI_API_KEY"
    },
    %{
      name: "glm-5.3-flash (high)",
      model: "zai_coding_plan:glm-5.3-flash",
      effort: "high",
      key: "ZAI_API_KEY"
    }
  ]

  setup %{tmp_dir: tmp_dir} do
    {:ok, _apps} = Application.ensure_all_started(:req_llm)

    runtime = :"lemieux_live_hardening_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    File.write!(Path.join(tmp_dir, "config.yaml"), """
    # The service reads this first, then the environment, then the flags.
    timeout_seconds: 30
    retries: 2
    """)

    File.write!(Path.join(tmp_dir, "README.md"), """
    # Fixture

    Configuration precedence is flags, then environment, then `config.yaml`.
    The default timeout is 30 seconds.
    """)

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp available?(%{key: key}) do
    case System.get_env(key) do
      value when is_binary(value) and value != "" -> true
      _otherwise -> false
    end
  end

  for configuration <- @configurations do
    @configuration configuration

    describe "#{configuration.name}" do
      test "a reflection asked for opportunities answers in records, not prose", context do
        if available?(@configuration) do
          mine(context, @configuration)
        else
          IO.puts("  skipped #{@configuration.name}: #{@configuration.key} is not exported")
        end
      end
    end
  end

  # One short real session, then `/reflect opportunities` over it, then the
  # ledger. Everything the TUI does for that command, minus the
  # screen.
  defp mine(context, configuration) do
    ledger = FeedbackJSONL.new(Path.join(context.tmp_dir, "feedback"))

    {:ok, session} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: ReqLLMProvider.new(),
        store: context.store,
        model: configuration.model,
        reasoning_effort: configuration.effort,
        subscriber: self(),
        cwd: context.tmp_dir,
        tools: Tools.default(),
        # Reasoning models count thinking against this, and the opportunity
        # contract asks for a JSON array: live GLM reflections stopped at
        # `:length` with 2048 and again with 8192, producing a half-written
        # array each time.
        params: [max_tokens: 16_384],
        max_turns: 6
      )

    id = Session.id(session)

    # A file that is not there, so the transcript carries a real tool failure
    # and recovery. A reflection over an entirely clean run has nothing to
    # name, which tests the parser and not the instructions.
    :ok =
      Session.prompt(
        session,
        "Read settings.yaml and tell me the default timeout. If that file does not exist, " <>
          "find the right file and answer from it. Answer with the number only."
      )

    assert_receive {:lemieux, ^id, {:finished, reason}}, :timer.minutes(4)

    assert reason in [:stop, :end_turn],
           "#{configuration.name} did not finish: #{inspect(reason)}"

    assert :ok = Reflection.reflect(session, mode: :opportunities)
    # Generous on purpose: with the stream inactivity default raised to two
    # minutes, a reasoning model at medium effort thinks for as long as it
    # needs to rather than being cut off, and this waits for the answer
    # instead of measuring the model.
    assert_receive {:lemieux, ^id, {:finished, reflected}}, :timer.minutes(8)

    # `:length` is a legitimate live outcome — the contract asks for a JSON
    # array and a reasoning model spends its output budget thinking — and the
    # harness reports it rather than passing a truncated array off as "no
    # opportunities". What must not happen is a crash or a provider failure.
    assert reflected in [:stop, :end_turn, :length],
           "#{configuration.name} reflection did not finish: #{inspect(reflected)}" <>
             errors(Session.snapshot(session).entries)

    snapshot = Session.snapshot(session)
    assert {:ok, ids} = Feedback.harvest(snapshot, feedback_store: ledger)

    answer = latest_assistant(snapshot.entries)

    IO.puts(
      "  #{configuration.name}: #{length(ids)} opportunities from a #{length(snapshot.entries)}-entry " <>
        "transcript; answer began #{inspect(String.slice(answer, 0, 80))}"
    )

    # Zero is a legitimate answer — the evidence may not justify one — but the
    # answer has to be the contract's shape, and anything it named has to have
    # reached the ledger as a model-authored record.
    assert String.contains?(answer, "[") or ids == [],
           "#{configuration.name} answered outside the output contract: #{inspect(answer)}"

    if reflected == :length,
      do: IO.puts("  #{configuration.name}: the reflection was cut off by its output limit")

    Enum.each(ids, fn feedback_id ->
      assert {:ok, record} = FeedbackStore.latest(ledger, feedback_id)
      assert record.actor["type"] == "model"
      assert record.provenance["host"] == "reflection"
      assert record.provenance["session_id"] == id
      assert record.raw_text != ""
    end)
  end

  # A live failure is almost always about the account or the request rather
  # than the code, so whatever the provider said goes in front of whoever
  # reads the failure.
  defp errors(entries) do
    entries
    |> Enum.filter(&(&1.type == :error))
    |> Enum.map_join("", &"\n    #{&1.payload["category"]}: #{&1.payload["reason"]}")
  end

  defp latest_assistant(entries) do
    case Lemieux.Transcript.latest_assistant_text(entries) do
      {:ok, text} -> text
      {:error, :not_found} -> ""
    end
  end

  # ---------------------------------------------------------------------------

  @delegating %{
    name: "gpt-5.6-luna",
    model: "openai:gpt-5.6-luna",
    effort: "low",
    key: "OPENAI_API_KEY"
  }

  test "a real child's findings reach the parent whatever shape they arrive in", context do
    if available?(@delegating) do
      delegate(context, @delegating)
    else
      IO.puts("  skipped delegation: #{@delegating.key} is not exported")
    end
  end

  defp delegate(context, configuration) do
    {:ok, parent} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: ReqLLMProvider.new(),
        store: context.store,
        model: configuration.model,
        reasoning_effort: configuration.effort,
        subscriber: self(),
        cwd: context.tmp_dir,
        tools: [],
        params: [max_tokens: 1024]
      )

    definition =
      Definition.new(
        id: "investigator",
        description: "Reads files and answers one question about them",
        # Deliberately says nothing about JSON beyond the schema the runtime
        # appends: this is the case the strict envelope used to lose.
        system_prompt: "Answer the question from the files. Cite what you read.",
        model: configuration.model,
        tools: [Tools.Read],
        max_turns: 6,
        timeout: :timer.minutes(2),
        max_cost_usd: 0.25
      )

    requests = [
      Request.new(definition, brief("What is the default timeout in config.yaml?")),
      Request.new(definition, brief("What is the configuration precedence in README.md?"))
    ]

    assert {:ok, group} =
             Subagent.spawn_many(parent, requests,
               max_cost_usd: 1.0,
               timeout: :timer.minutes(3)
             )

    assert {:ok, result} = Subagent.await(group, :timer.minutes(3))

    for child <- result.results do
      IO.puts(
        "  child #{child.definition_id}: #{child.status}/#{child.format} · " <>
          "#{inspect(String.slice(child.answer, 0, 70))}"
      )
    end

    # The whole point of the change: a child that answered reports it, in
    # whatever shape it answered. A live child can still miss its deadline or
    # lose its connection — that is the network, not the envelope — so what is
    # asserted is that nothing was discarded *for its shape*.
    Enum.each(result.results, fn child ->
      if child.status == :ok do
        refute child.answer == "", "#{child.definition_id} came back ok reporting nothing"
        assert child.format in [:structured, :prose]
      else
        refute Enum.any?(child.uncertainties, &(&1 =~ "outside the result schema")),
               "#{child.definition_id} was discarded for its shape: #{inspect(child.uncertainties)}"
      end
    end)

    answered = Enum.filter(result.results, &(&1.status == :ok))
    assert answered != [], "no child answered at all: #{inspect(result.results)}"

    assert Enum.any?(answered, &(&1.answer =~ ~r/30|flag|environment/i)),
           "no child reported what it read: #{inspect(Enum.map(answered, & &1.answer))}"
  end

  defp brief(objective) do
    SubagentTask.new(
      objective: objective,
      expected_evidence: ["the file you read"],
      snapshot: %{"fixture" => "live-hardening"}
    )
  end

  # ---------------------------------------------------------------------------

  test "a stream that stalls mid-answer is classified as a timeout, not a refusal",
       context do
    if available?(%{key: "OPENAI_API_KEY"}) do
      stall(context)
    else
      IO.puts("  skipped stream timeout: OPENAI_API_KEY is not exported")
    end
  end

  # A one-millisecond transport timeout against a real endpoint produces the
  # exact failure the evaluation lane now keys on. Nothing else reproduces it
  # without waiting for a bad day on somebody's network.
  defp stall(context) do
    {:ok, session} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: ReqLLMProvider.new(receive_timeout: 1, pool_timeout: 1),
        store: context.store,
        model: "openai:gpt-5.4-nano",
        subscriber: self(),
        cwd: context.tmp_dir,
        tools: [],
        params: [max_tokens: 64]
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "Say hello.")
    assert_receive {:lemieux, ^id, {:finished, :error}}, :timer.seconds(60)

    entries = Session.snapshot(session).entries
    assert [error | _rest] = entries |> Enum.filter(&(&1.type == :error)) |> Enum.reverse()

    IO.puts(
      "  stalled stream: category=#{error.payload["category"]} · #{error.payload["reason"]}"
    )

    assert error.payload["category"] == "timeout",
           "a stalled stream was classified #{inspect(error.payload)}"
  end
end

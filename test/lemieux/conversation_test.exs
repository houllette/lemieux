defmodule Lemieux.ConversationTest do
  use ExUnit.Case, async: true

  alias Lemieux.Context
  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command.Builtin
  alias Lemieux.Entry
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Providers.Scripted
  alias ReqLLM.Error.API.Request

  defp conversation(fields \\ []) do
    struct!(Conversation.new(model: "test:model"), fields)
  end

  # What a host that applied `Lemieux.Extensions.Elixir` with its commands has:
  # `/elixir`, `/attach` and `/detach` are not built-ins.
  defp elixir_conversation(fields \\ []) do
    struct!(Conversation.new(model: "test:model", commands: Builtin.elixir()), fields)
  end

  # The effects are the interface, so the tests read them rather than the
  # struct wherever both would do.
  defp effects(conversation, line), do: conversation |> Conversation.input(line) |> elem(1)
  defp said(effects), do: for({:say, text} <- effects, do: text) |> Enum.join("\n")

  test "/reflect is discoverable, policy controlled and refused while busy" do
    {reflecting, actions} = Conversation.input(conversation(), "/reflect")
    assert {:reflect, :assessment} in actions
    refute reflecting.busy?
    assert Enum.any?(Conversation.commands(), &(&1.name == "reflect"))

    refute Enum.any?(
             Conversation.commands(fn
               {:reflect, _mode} -> {:deny, "disabled"}
               _ -> :allow
             end),
             &(&1.name == "reflect")
           )

    assert Conversation.command_action?({:reflect, :assessment})
    refute {:reflect, :assessment} in effects(conversation(busy?: true), "/reflect")
    {idle, _} = Conversation.event(reflecting, {:reflection_result, {:error, :busy}})
    refute idle.busy?
    assert idle.reflecting == nil
  end

  # Busy from the moment the front end asks, not from the model's first token:
  # a reflection is a turn, and a line typed while it runs is a steer. The parse
  # cannot mark it, because a host policy may still refuse the command.
  test "a reflection the front end started is a busy conversation" do
    {reflecting, _actions} = Conversation.input(conversation(), "/reflect")
    refute reflecting.busy?

    assert {started, []} = Conversation.event(reflecting, {:reflection_started, :assessment})
    assert started.busy?
    assert started.reflecting == :assessment

    assert [{:steer, "faster"} | _said] = effects(started, "faster")
  end

  describe "/reflect opportunities" do
    test "asks for the opportunity mode and mines the answer once the turn ends" do
      {mining, actions} = Conversation.input(conversation(), "/reflect opportunities")

      assert {:reflect, :opportunities} in actions
      assert mining.reflecting == :opportunities

      # The turn ends and the answer exists; the mining is asked for before the
      # prompt comes back, so records are written before another line lands.
      {done, effects} = Conversation.event(%{mining | busy?: true}, {:finished, :stop})

      assert :mine_opportunities in effects
      refute :ready in effects
      assert done.reflecting == nil
    end

    test "a reflection cut off by its output limit says so before mining" do
      {mining, _actions} = Conversation.input(conversation(), "/reflect opportunities")
      {_done, effects} = Conversation.event(%{mining | busy?: true}, {:finished, :length})

      assert said(effects) =~ "ran out of output tokens"
      # Still mined: a truncated array may hold whole opportunities before the
      # cut, and the warning is what keeps zero from reading as "nothing to say".
      assert :mine_opportunities in effects
    end

    test "an ordinary reflection mines nothing when its turn ends" do
      {reflecting, _actions} = Conversation.input(conversation(), "/reflect")
      {_done, effects} = Conversation.event(%{reflecting | busy?: true}, {:finished, :stop})

      refute :mine_opportunities in effects
      assert :ready in effects
    end

    test "records land with their ids, prose lands as nothing recorded" do
      assert said(elem(Conversation.event(conversation(), {:opportunities_result, {:ok, []}}), 1)) =~
               "no opportunities"

      recorded =
        Conversation.event(conversation(), {:opportunities_result, {:ok, ["fb_1", "fb_2"]}})

      assert said(elem(recorded, 1)) =~ "recorded 2 opportunities"
      assert said(elem(recorded, 1)) =~ "fb_1"
    end

    test "an unknown argument is refused rather than guessed at" do
      assert said(effects(conversation(), "/reflect everything")) =~ "usage: /reflect"
      refute Enum.any?(effects(conversation(), "/reflect everything"), &match?({:reflect, _}, &1))
    end
  end

  describe "/feedback" do
    defp anchors do
      [
        %{id: "e3", seq: 3, label: "#3 assistant · done"},
        %{id: "e1", seq: 1, label: "#1 user · fix the thing"}
      ]
    end

    # The whole dialogue, driven the way a person drives it. What matters is
    # the submission it ends with: the anchor they chose and the words they
    # typed, unedited.
    defp capture(conversation, lines) do
      Enum.reduce(lines, {conversation, []}, fn line, {conversation, _effects} ->
        Conversation.input(conversation, line)
      end)
    end

    test "opens on anchors the front end supplies and submits what was chosen" do
      {asking, actions} = Conversation.input(conversation(), "/feedback")
      assert :feedback in actions

      {opened, effects} = Conversation.event(asking, {:feedback_anchors, anchors()})
      assert said(effects) =~ "What should have gone differently?"
      assert opened.feedback

      # prose, anchor 2, type bug, scope project (blank), durability always
      {_done, effects} =
        capture(opened, ["it should have run the formatter", "2", "bug", "", "always"])

      assert [
               {:feedback,
                %{
                  text: "it should have run the formatter",
                  entry_id: "e1",
                  type: :bug,
                  scope: :project,
                  durability: :standing_rule,
                  questions_asked: 3
                }}
             ] = effects
    end

    test "prose given with the command skips straight to the anchor, and blank takes the newest" do
      {asking, _actions} = Conversation.input(conversation(), "/feedback tests were never run")
      {opened, effects} = Conversation.event(asking, {:feedback_anchors, anchors()})

      assert said(effects) =~ "Which moment is this about?"
      assert said(effects) =~ "#3 assistant"

      {_done, effects} = capture(opened, ["", "", "", ""])

      assert [{:feedback, submission}] = effects
      assert submission.text == "tests were never run"
      assert submission.entry_id == "e3"
      assert submission.type == :unknown
      assert submission.durability == :one_off
    end

    test "nothing is sent to the model, and nothing reaches the transcript" do
      {asking, _actions} = Conversation.input(conversation(), "/feedback")
      {opened, _effects} = Conversation.event(asking, {:feedback_anchors, anchors()})
      {final, effects} = capture(opened, ["it broke", "1", "bug", "task", "once"])

      every = Enum.flat_map([effects], & &1)
      refute Enum.any?(every, &match?({:prompt, _text}, &1))
      refute Enum.any?(every, &match?({:steer, _text}, &1))
      refute final.busy?
    end

    test "a command typed mid-capture waits, and /cancel discards" do
      {asking, _actions} = Conversation.input(conversation(), "/feedback")
      {opened, _effects} = Conversation.event(asking, {:feedback_anchors, anchors()})

      {still_open, effects} = Conversation.input(opened, "/help")
      assert said(effects) =~ "finish the feedback, or /cancel it"
      assert still_open.feedback
      refute :help in effects

      {cancelled, effects} = Conversation.input(still_open, "/cancel")
      assert said(effects) =~ "feedback discarded"
      refute cancelled.feedback
    end

    test "an unrecognised answer re-asks rather than guessing" do
      {asking, _actions} = Conversation.input(conversation(), "/feedback it broke")
      {opened, _effects} = Conversation.event(asking, {:feedback_anchors, anchors()})

      {still_asking, effects} = Conversation.input(opened, "9")
      assert said(effects) =~ "choose 1 to 2"
      assert still_asking.feedback.step == :anchor
    end

    test "a session with nothing to point at says so instead of inventing an anchor" do
      {asking, _actions} = Conversation.input(conversation(), "/feedback")
      {closed, effects} = Conversation.event(asking, {:feedback_anchors, []})

      assert said(effects) =~ "nothing to anchor feedback to yet"
      refute closed.feedback
    end

    test "is refused mid-turn, so a correction stays a steer" do
      busy = conversation(busy?: true)
      effects = effects(busy, "/feedback the tests are failing")

      assert said(effects) =~ "wait for it to finish"
      refute :feedback in effects
      # And the same words typed without the command still steer.
      assert {:steer, "the tests are failing"} in effects(busy, "the tests are failing")
    end

    test "is discoverable and policy controlled" do
      assert Enum.any?(Conversation.commands(), &(&1.name == "feedback"))
      assert Conversation.command_action?(:feedback)

      refute Enum.any?(
               Conversation.commands(fn
                 :feedback -> {:deny, "not here"}
                 _ -> :allow
               end),
               &(&1.name == "feedback")
             )
    end

    test "the ledger's answer is reported either way" do
      {_conversation, effects} =
        Conversation.event(conversation(), {:feedback_result, {:ok, "fb_123"}})

      assert said(effects) =~ "fb_123 captured"
      assert said(effects) =~ "not part of this conversation"

      {_conversation, effects} =
        Conversation.event(conversation(), {:feedback_result, {:error, :eacces}})

      assert said(effects) =~ "could not capture feedback"
    end
  end

  describe "a line typed at the prompt" do
    test "is a prompt to the model, and the conversation becomes busy" do
      assert {conversation, effects} = Conversation.input(conversation(), "say hi")

      assert {:prompt, "say hi"} in effects
      assert conversation.busy?
    end

    test "an empty one asks the model nothing" do
      assert {conversation, effects} = Conversation.input(conversation(), "")

      refute conversation.busy?
      refute Enum.any?(effects, &match?({:prompt, _text}, &1))
      assert :ready in effects
    end
  end

  describe "a line typed while the model is working" do
    # The line that makes an interactive session worth having over `lmx run`:
    # busy is not a reason to refuse input, it is the reason steering exists.
    test "steers the turn rather than starting another" do
      conversation = conversation(busy?: true)

      assert {still_busy, effects} = Conversation.input(conversation, "actually, use tabs")

      assert {:steer, "actually, use tabs"} in effects
      refute Enum.any?(effects, &match?({:prompt, _text}, &1))
      assert still_busy.busy?
    end

    test "and the person is told it landed, because nothing else says so" do
      assert conversation(busy?: true) |> effects("hint") |> said() =~ "noted"
    end
  end

  describe "a line typed while the agent is waiting on an answer" do
    test "answers the question rather than starting a turn" do
      conversation = conversation(busy?: true, asking: "call-1")

      assert {answered, effects} = Conversation.input(conversation, "teal")

      assert {:answer, "call-1", "teal"} in effects
      refute Enum.any?(effects, &match?({:steer, _text}, &1))
      assert answered.asking == nil
    end

    test "a numbered choice returns its label while custom text remains free-form" do
      question = %{
        call_id: "call-1",
        question: "which database?",
        options: [
          %{label: "Postgres", description: "Use the existing service"},
          %{label: "SQLite", description: nil}
        ]
      }

      {asking, effects} = Conversation.event(conversation(busy?: true), {:question, question})

      assert asking.question == question
      assert said(effects) =~ "1. Postgres — Use the existing service"
      assert said(effects) =~ "2. SQLite"
      assert {_answered, [{:answer, "call-1", "SQLite"}]} = Conversation.input(asking, "2")

      {asking, _effects} = Conversation.event(conversation(busy?: true), {:question, question})

      assert {_answered, [{:answer, "call-1", "something else"}]} =
               Conversation.input(asking, "something else")
    end
  end

  test "receipt estimates stay in status, preserve detail, and never become billed spending" do
    unpriced = %{"input_tokens" => 10, "output_tokens" => 2, "cost_usd" => nil}
    measured = %{"input_tokens" => 4, "output_tokens" => 1, "cost_usd" => 0.01}

    observation = %{
      "kind" => "ixway_api_equivalent",
      "request_id" => "receipt-one",
      "data" => %{
        "state" => "estimated",
        "amount" => "0.0011273",
        "reference_provider" => "openai",
        "reference_source" => "llm_db/gpt-6-luna",
        "excludes" => ["subscription_fee", "api_tool_fees"]
      },
      "text" => "API equivalent estimate: $0.0011273 USD"
    }

    {first, []} = Conversation.event(conversation(), {:usage, unpriced})
    {estimated, []} = Conversation.event(first, {:route_observation, observation})
    assert Conversation.cost(estimated) == "estimated cost: $0.0011273"
    assert estimated.spent_usd == nil
    assert Conversation.context_report(estimated) =~ "openai / llm_db/gpt-6-luna"
    assert Conversation.context_report(estimated) =~ "subscription fee, api tool fees"

    {deduplicated, []} = Conversation.event(estimated, {:route_observation, observation})
    assert Conversation.cost(deduplicated) == "estimated cost: $0.0011273"

    second =
      observation
      |> Map.put("request_id", "receipt-two")
      |> put_in(["data", "amount"], "0.0011259")

    {two_receipts, []} = Conversation.event(deduplicated, {:usage, unpriced})
    {two_receipts, []} = Conversation.event(two_receipts, {:route_observation, second})
    assert Conversation.cost(two_receipts) == "estimated cost: $0.0022532"

    {mixed, []} = Conversation.event(two_receipts, {:usage, measured})

    assert Conversation.cost(mixed) ==
             "estimated cost: $0.0022532 + measured cost: $0.0100 " <>
               "(≈ total cost: $0.0122532)"

    assert mixed.spent_usd == nil
    assert_in_delta mixed.measured_spent_usd, 0.01, 0.000_000_1
  end

  test "unavailable receipt remains unknown with its reason and measured subtotal" do
    usage = %{"input_tokens" => 10, "output_tokens" => 2, "cost_usd" => nil}
    {unpriced, []} = Conversation.event(conversation(), {:usage, usage})

    {unknown, []} =
      Conversation.event(unpriced, {
        :route_observation,
        %{
          "kind" => "ixway_api_equivalent",
          "request_id" => "receipt-two",
          "data" => %{"state" => "unknown", "reason" => "receipt_timeout", "excludes" => []}
        }
      })

    assert Conversation.cost(unknown) == "estimated cost: unknown (receipt_timeout)"

    assert {mixed, []} =
             Conversation.event(unknown, {:usage, %{"input_tokens" => 2, "cost_usd" => 0.02}})

    assert Conversation.cost(mixed) ==
             "estimated cost: unknown (receipt_timeout) + measured cost: $0.0200"

    assert mixed.spent_usd == nil
  end

  test "a missing second receipt prevents a misleading approximate total" do
    usage = %{"input_tokens" => 10, "output_tokens" => 2, "cost_usd" => nil}
    {first, []} = Conversation.event(conversation(), {:usage, usage})

    {first, []} =
      Conversation.event(first, {
        :route_observation,
        %{
          "kind" => "ixway_api_equivalent",
          "request_id" => "one",
          "data" => %{"state" => "estimated", "amount" => "0.001"}
        }
      })

    {second, []} = Conversation.event(first, {:usage, usage})
    assert Conversation.cost(second) == "estimated cost: $0.001 + unknown estimate"

    {unknown, []} =
      Conversation.event(second, {
        :route_observation,
        %{
          "kind" => "ixway_api_equivalent",
          "request_id" => "two",
          "data" => %{"state" => "unknown", "reason" => "receipt_not_found"}
        }
      })

    assert Conversation.cost(unknown) ==
             "estimated cost: $0.001 + unknown estimate: receipt_not_found"
  end

  test "resuming reconstructs measured and unpriced requests without restoring receipt estimates" do
    entries = [
      Entry.new(:assistant, %{"text" => "API response"},
        usage: %{"input_tokens" => 2, "cost_usd" => 0.02}
      ),
      Entry.new(:assistant, %{"text" => "subscription response"},
        usage: %{"input_tokens" => 2, "cost_usd" => nil}
      )
    ]

    resumed = Conversation.restore_usage(conversation(), entries)
    assert resumed.measured_spent_usd == 0.02
    assert resumed.unmeasured_requests == 1
    assert resumed.estimated_usd == nil

    {resumed, []} =
      Conversation.event(resumed, {:usage, %{"input_tokens" => 2, "cost_usd" => nil}})

    {estimated, []} =
      Conversation.event(resumed, {
        :route_observation,
        %{
          "kind" => "ixway_api_equivalent",
          "request_id" => "new",
          "data" => %{"state" => "estimated", "amount" => "0.001"}
        }
      })

    assert Conversation.cost(estimated) =~ "measured cost: $0.0200 (≈ total cost: unknown)"
  end

  describe "commands" do
    test "/quit leaves" do
      assert :quit in effects(conversation(), "/quit")
      assert :quit in effects(conversation(), "/exit")
    end

    test "/help lists them rather than asking the model" do
      said = conversation() |> effects("/help") |> said()

      assert said =~ "/context"
      assert said =~ "/compact"
      assert said =~ "/copy"
      assert said =~ "/cancel"
      assert said =~ "/quit"
    end

    test "/copy asks the front end to copy the latest assistant response" do
      assert {_conversation, [:copy]} = Conversation.input(conversation(), "/copy")

      assert {_conversation, [:copy]} =
               Conversation.input(conversation(busy?: true), "/copy")
    end

    test "policy-aware help omits denied subcommands without hiding allowed status" do
      policy = fn
        {:mcp_add, _path} -> {:deny, "no MCP mutations"}
        {:mcp_remove, _name} -> {:deny, "no MCP mutations"}
        {:mcp_reconnect, _name} -> {:deny, "no MCP mutations"}
        _action -> :allow
      end

      help = Conversation.help(policy)

      assert help =~ "/mcp"
      refute help =~ "/mcp add"
      refute help =~ "remove NAME"
      refute help =~ "reconnect [NAME]"
    end

    test "/cancel stops a turn that is running" do
      assert :cancel in effects(conversation(busy?: true), "/cancel")
    end

    test "/cancel with nothing running says so instead of cancelling" do
      effects = effects(conversation(), "/cancel")

      refute :cancel in effects
      assert said(effects) =~ "nothing to cancel"
    end

    test "a question in flight is dropped when the turn is cancelled" do
      conversation = conversation(busy?: true, asking: "call-1")

      assert {cancelled, _effects} = Conversation.input(conversation, "/cancel")
      assert cancelled.asking == nil
    end

    test "an unknown one is named rather than sent to the model" do
      effects = effects(conversation(), "/nope")

      refute Enum.any?(effects, &match?({:prompt, _text}, &1))
      assert said(effects) =~ "/nope"
    end

    test "/compact waits rather than summarising underneath a running turn" do
      effects = effects(conversation(busy?: true), "/compact")

      refute :compact in effects
      assert said(effects) =~ "wait"
    end

    test "/compact summarises when nothing is running" do
      assert :compact in effects(conversation(), "/compact")
    end

    test "/new starts another session when nothing is running" do
      assert :new in effects(conversation(), "/new")
      refute Enum.any?(Conversation.commands(), &(&1.name == "clear"))
      assert said(effects(conversation(), "/clear")) =~ "not a command"
    end

    test "/new waits rather than abandoning a running turn" do
      effects = effects(conversation(busy?: true), "/new")

      refute :new in effects
      assert said(effects) =~ "wait"
    end

    test "clearing reports what stopped being sent, and that it still exists" do
      {_conversation, effects} = Conversation.event(conversation(), {:cleared, %{entries: 12}})

      assert said(effects) =~ "12"
      assert said(effects) =~ "transcript"
    end

    # The session emits `{:cleared, …}` whether the command came from here or
    # from a host holding the same session, so it is the one line that reports
    # it. A second line from the result would be the same fact twice.
    test "a successful clear is reported once, by the event rather than the result" do
      {_conversation, effects} =
        Conversation.event(conversation(), {:clear_result, {:ok, %{entries: 12}}})

      assert said(effects) == ""
    end

    test "clearing an already-empty context says so rather than claiming success" do
      {_conversation, effects} =
        Conversation.event(conversation(), {:clear_result, {:error, :nothing_to_do}})

      assert said(effects) =~ "nothing to clear"
    end

    test "/elixir toggles the tool profile only while idle" do
      assert :toggle_elixir_mode in effects(elixir_conversation(), "/elixir")
      refute :toggle_elixir_mode in effects(elixir_conversation(busy?: true), "/elixir")
    end

    test "/elixir is not a command where the Elixir extension offered none" do
      assert said(effects(conversation(), "/elixir")) =~ "not a command"
    end

    test "/habs is parsed but never listed" do
      assert :habs in effects(conversation(), "/habs")
      refute Conversation.help() =~ "/habs"
      refute Enum.any?(Conversation.commands(), &(&1.name == "habs"))
    end

    test "an unknown slash command still says so" do
      assert said(elem(Conversation.input(conversation(), "/canadiens"), 1)) =~ "not a command"
    end

    test "Elixir mode keeps the interactive question tool without calling it execution" do
      {_conversation, effects} =
        Conversation.event(conversation(), {:tools_changed, ["read"], ["elixir", "ask_user"]})

      message = said(effects)
      assert message =~ "the file tools are off"
      assert message =~ "also: ask_user"
      refute message =~ "mode off"
    end

    # The message used to be a literal list of the two catalogs the mode could
    # produce, so the catalog gaining anything made turning the mode *on*
    # announce that it was off.
    test "Elixir mode is recognised by what is gone, not by an exact list" do
      {_conversation, effects} =
        Conversation.event(
          conversation(),
          {:tools_changed, ["read"], ["elixir", "ask_user", "delegate"]}
        )

      message = said(effects)
      assert message =~ "Elixir mode on"
      assert message =~ "also: ask_user, delegate"
      refute message =~ "mode off"
    end

    test "a catalog with a file tool in it is not Elixir mode, whatever else it holds" do
      {_conversation, effects} =
        Conversation.event(
          conversation(),
          {:tools_changed, ["elixir"], ["elixir", "read", "delegate"]}
        )

      assert said(effects) =~ "Elixir mode off"
    end

    test "attaching without a name asks for the list rather than guessing" do
      assert {_conversation, [{:attach, nil}]} =
               Conversation.input(elixir_conversation(), "/attach")
    end

    test "attaching with a name carries it, trimmed" do
      assert {_conversation, [{:attach, "myapp"}]} =
               Conversation.input(elixir_conversation(), "/attach  myapp  ")
    end

    test "detaching is its own effect" do
      assert {_conversation, [:detach]} = Conversation.input(elixir_conversation(), "/detach")
    end

    test "the Elixir commands are listed where they are offered, and only there" do
      assert Conversation.help(elixir_conversation()) =~ "/attach"
      assert Conversation.help(elixir_conversation()) =~ "/detach"
      assert Conversation.help(elixir_conversation()) =~ "/elixir"

      refute Conversation.help() =~ "/attach"
      refute Conversation.help() =~ "/elixir"
    end

    test "provider switching is separate from the provider-scoped model command" do
      assert {_conversation, [:provider_status]} = Conversation.input(conversation(), "/provider")

      assert {_conversation, [{:set_provider, "openai"}]} =
               Conversation.input(conversation(), "/provider  openai  ")

      assert {_conversation, [:model_status]} = Conversation.input(conversation(), "/model")

      assert {_conversation, [{:set_model, "test:gpt-5"}]} =
               Conversation.input(conversation(), "/model  gpt-5  ")

      assert {_conversation, [{:set_model, "test:qwen:tag"}]} =
               Conversation.input(conversation(), "/model qwen:tag")

      effects = effects(conversation(busy?: true), "/model gpt-5")
      refute Enum.any?(effects, &match?({:set_model, _model}, &1))
      assert said(effects) =~ "wait"
    end

    test "reasoning effort is selectable only while idle" do
      assert {_conversation, [:reasoning_effort_status]} =
               Conversation.input(conversation(), "/effort")

      assert {_conversation, [{:set_reasoning_effort, "high"}]} =
               Conversation.input(conversation(), "/effort  high  ")

      effects = effects(conversation(busy?: true), "/effort high")
      refute Enum.any?(effects, &match?({:set_reasoning_effort, _effort}, &1))
      assert said(effects) =~ "wait"
    end

    # Deliberately not "only while idle", unlike the two above: a caption and
    # a colour change nothing about the turn, and having to stop watching
    # something in order to label it would be absurd.
    test "the session's caption is set, asked about, and reset, turn or no turn" do
      assert {_conversation, [:name_status]} = Conversation.input(conversation(), "/name")
      assert {_conversation, [:name_status]} = Conversation.input(conversation(), "/name   ")

      assert {_conversation, [{:set_name, "the refactor"}]} =
               Conversation.input(conversation(), "/name  the refactor  ")

      assert {_conversation, [{:set_name, "default"}]} =
               Conversation.input(conversation(), "/name default")

      assert {_conversation, [{:set_name, "mid turn"}]} =
               Conversation.input(conversation(busy?: true), "/name mid turn")
    end

    test "the screen's accent is set and asked about under either spelling" do
      for command <- ["/color", "/colour"] do
        assert {_conversation, [:colour_status]} = Conversation.input(conversation(), command)

        assert {_conversation, [{:set_colour, "magenta"}]} =
                 Conversation.input(conversation(), command <> "  magenta ")

        assert {_conversation, [:colour_status]} =
                 Conversation.input(conversation(busy?: true), command)
      end
    end

    test "the screen's palette is set and asked about, mid-turn too" do
      assert {_conversation, [:theme_status]} = Conversation.input(conversation(), "/theme")
      assert {_conversation, [:theme_status]} = Conversation.input(conversation(), "/theme  ")

      assert {_conversation, [{:set_theme, "light"}]} =
               Conversation.input(conversation(), "/theme  light ")

      assert {_conversation, [{:set_theme, "mono"}]} =
               Conversation.input(conversation(busy?: true), "/theme mono")

      assert %{name: "theme", accepts_arguments?: true} =
               Enum.find(Conversation.commands(), &(&1.name == "theme"))
    end

    test "resume lists sessions, selects one while idle, and refuses mid-turn" do
      assert {_conversation, [:resume_status]} = Conversation.input(conversation(), "/resume")

      assert {_conversation, [{:resume, "01STORED"}]} =
               Conversation.input(conversation(), "/resume 01STORED")

      effects = effects(conversation(busy?: true), "/resume 01STORED")
      refute Enum.any?(effects, &match?({:resume, _id}, &1))
      assert said(effects) =~ "cancel or wait"
    end

    test "mcp commands expose status, config loading, removal and reconnect" do
      assert {_conversation, [:mcp_status]} = Conversation.input(conversation(), "/mcp")
      assert {_conversation, [:mcp_status]} = Conversation.input(conversation(), "/mcp list")

      assert {_conversation, [{:mcp_add, "mcp.json"}]} =
               Conversation.input(conversation(), "/mcp add mcp.json")

      assert {_conversation, [{:mcp_remove, "github"}]} =
               Conversation.input(conversation(), "/mcp remove github")

      assert {_conversation, [{:mcp_reconnect, :all}]} =
               Conversation.input(conversation(), "/mcp reconnect")

      assert {_conversation, [{:mcp_reconnect, "github"}]} =
               Conversation.input(conversation(), "/mcp reconnect github")
    end

    test "mcp mutations wait for a running turn and malformed commands explain the syntax" do
      effects = effects(conversation(busy?: true), "/mcp remove github")
      refute Enum.any?(effects, &match?({:mcp_remove, _name}, &1))
      assert said(effects) =~ "wait"

      assert conversation() |> effects("/mcp nope") |> said() =~ "usage:"
    end

    test "tools list while busy, but enable and disable only while idle" do
      assert {_conversation, [:tools_status]} = Conversation.input(conversation(), "/tools")
      assert {_conversation, [:tools_status]} = Conversation.input(conversation(), "/tools list")

      assert {_conversation, [{:enable_tools, ["read", "bash"]}]} =
               Conversation.input(conversation(), "/tools enable read bash")

      assert {_conversation, [{:disable_tools, ["write"]}]} =
               Conversation.input(conversation(), "/tools disable write")

      effects = effects(conversation(busy?: true), "/tools disable bash")
      refute Enum.any?(effects, &match?({:disable_tools, _names}, &1))
      assert said(effects) =~ "wait"
    end

    test "malformed tool commands explain the syntax" do
      assert conversation() |> effects("/tools enable") |> said() =~ "usage:"
      assert conversation() |> effects("/tools nope") |> said() =~ "usage:"
    end

    test "command metadata is the autocomplete source and includes aliases" do
      assert %{name: "quit", aliases: ["exit"]} =
               Enum.find(Conversation.commands(), &(&1.name == "quit"))

      assert Enum.any?(Conversation.commands(), &(&1.name == "model"))
      assert Enum.any?(Conversation.commands(), &(&1.name == "provider"))
      assert Enum.any?(Conversation.commands(), &(&1.name == "effort"))

      assert %{name: "color", aliases: ["colour"]} =
               Enum.find(Conversation.commands(), &(&1.name == "color"))

      assert Enum.any?(Conversation.commands(), &(&1.name == "name"))
      assert Enum.any?(Conversation.commands(), &(&1.name == "resume"))
      assert Enum.any?(Conversation.commands(), &(&1.name == "mcp"))
      assert Enum.any?(Conversation.commands(), &(&1.name == "tools"))
      assert Enum.any?(Conversation.commands(), &(&1.name == "copy"))
      assert Enum.any?(Conversation.commands(), &(&1.name == "new"))
    end

    # The other drift direction, which nothing caught before: a name declared
    # in `@commands` with no `typed/2` clause is listed by help and offered by
    # autocomplete, and then answers "is not a command" when somebody takes
    # the offer.
    test "every declared command, and every alias, is a command when typed" do
      for command <- Conversation.commands(),
          name <- [command.name | command.aliases] do
        said = said(effects(conversation(), "/" <> name))

        refute said =~ "is not a command", "/#{name} is listed but does not parse"
      end
    end

    test "/refresh asks the session to re-read what it attached" do
      assert :refresh in effects(conversation(), "/refresh")
    end

    test "/refresh waits its turn rather than racing a running one" do
      assert said(effects(conversation(busy?: true), "/refresh")) == "wait for it to finish first"
    end

    test "a refresh that found nothing says so rather than nothing" do
      assert {_conversation, effects} =
               Conversation.event(conversation(), {:refresh_result, {:ok, 0}})

      assert said(effects) == "every attached file is current"
    end

    test "a refresh that found something counts it" do
      assert {_conversation, effects} =
               Conversation.event(conversation(), {:refresh_result, {:ok, 2}})

      assert said(effects) == "re-attached 2 changed files"
    end

    test "a refresh that failed says why" do
      assert {_conversation, effects} =
               Conversation.event(conversation(), {:refresh_result, {:error, :busy}})

      assert said(effects) =~ "could not refresh"
    end

    # `commands/1` puts every declared name through `command_action/1` before
    # asking the host about it, so a command added without one takes the whole
    # list down — help and autocomplete included — rather than going missing
    # quietly. This is the test that catches that at the point of the mistake.
    test "every declared command has an action the host policy can be shown" do
      seen = :ets.new(:seen_actions, [:public, :bag])
      policy = fn action -> :ets.insert(seen, {:action, action}) && :allow end

      assert Conversation.commands(policy) == Conversation.commands()
      assert length(:ets.lookup(seen, :action)) == length(Conversation.commands())

      for {:action, action} <- :ets.lookup(seen, :action) do
        assert Conversation.command_action?(action), "#{inspect(action)} is not a command action"
      end
    end
  end

  describe "recovering from a provider failure" do
    test "/retry is an effect when idle and a refusal when busy" do
      assert [:retry] = effects(conversation(), "/retry")

      busy = %{conversation() | busy?: true}
      assert [{:say, "it is still running"}] = effects(busy, "/retry")
    end

    test "an automatic retry says what failed and how long the wait is" do
      [error: reason] = Scripted.http_error(503, reason: "gateway is restarting")

      retry = %{attempt: 1, max: 2, delay_ms: 2_000, category: :server, reason: reason}

      assert conversation() |> Conversation.event({:provider_retry, retry}) |> elem(1) |> said() ==
               "test returned HTTP 503: gateway is restarting · retrying in 2.0s (1/2)"

      limited = %{retry | category: :rate_limit, delay_ms: 30_000}

      assert conversation() |> Conversation.event({:provider_retry, limited}) |> elem(1) |> said() =~
               "test returned HTTP 503: gateway is restarting · retrying in 30.0s"
    end

    test "an Ixway HTTP error identifies the responding gateway rather than implying a local credential" do
      [error: reason] =
        Scripted.http_error(500, reason: "backend credentials are not configured")

      conversation = conversation(model: "ixway:gpt-6-luna")
      retry = %{attempt: 1, max: 2, delay_ms: 2_000, category: :server, reason: reason}

      assert conversation |> Conversation.event({:provider_retry, retry}) |> elem(1) |> said() ==
               "ixway returned HTTP 500: backend credentials are not configured · retrying in 2.0s (1/2)"

      assert conversation |> Conversation.event({:error, reason}) |> elem(1) |> said() ==
               "error: ixway returned HTTP 500: backend credentials are not configured · /retry to send the request again"
    end

    # The TUI's live row names the same wait, and used to keep its own copy of
    # these phrases. One table, read by both.
    test "the kind of failure is one vocabulary shared with the TUI" do
      assert Conversation.retry_kind(:rate_limit) == "rate limited"
      assert Conversation.retry_kind(:timeout) == "the provider went quiet"
      assert Conversation.retry_kind(:server) == "provider error"
      assert Conversation.retry_kind(nil) == "provider error"
    end

    test "an accepted retry is a turn in progress, and a refused one says why" do
      assert {%{busy?: true}, []} = Conversation.event(conversation(), {:retry_result, :ok})

      assert conversation()
             |> Conversation.event({:retry_result, {:error, :nothing_to_retry}})
             |> elem(1)
             |> said() == "nothing failed, so there is nothing to retry"
    end
  end

  describe "what the model is saying" do
    test "text arrives as a fragment, so it can be streamed rather than buffered" do
      assert {_conversation, effects} = Conversation.event(conversation(), {:text_delta, "hel"})

      assert effects == [{:write, "hel"}]
    end

    test "a tool call is announced with something of its arguments" do
      call = %{name: "read", arguments: %{"path" => "lib/lemieux.ex"}}

      assert conversation() |> Conversation.event({:tool_call, call}) |> elem(1) |> said() =~
               "read"
    end

    test "provider usage updates every current token class before the turn finishes" do
      usage = %{
        "input_tokens" => 110,
        "cache_read_tokens" => 100,
        "cache_write_tokens" => 20,
        "output_tokens" => 7,
        "input_includes_cached" => true
      }

      assert {updated, []} = Conversation.event(conversation(), {:usage, usage})
      assert updated.context.current == %{input: 0, cached: 100, cache_write: 20, output: 7}

      # The per-class split is `/context`'s now; the status line answers
      # where the window stands and what the session has been billed.
      assert Conversation.status(updated) =~ "127 tokens"
    end

    test "delegated usage contributes to total cost without replacing the parent's context" do
      direct = %{
        "input_tokens" => 10,
        "output_tokens" => 2,
        "cache_read_tokens" => 0,
        "cache_write_tokens" => 0,
        "cost_usd" => 0.01
      }

      delegated = %{
        "input_tokens" => 40,
        "output_tokens" => 5,
        "cache_read_tokens" => 3,
        "cache_write_tokens" => 0,
        "cost_usd" => 0.02
      }

      assert {parent, []} = Conversation.event(conversation(), {:usage, direct})

      assert {updated, []} =
               Conversation.event(
                 parent,
                 {:subagent, ["root", "child"], {:usage, delegated}}
               )

      assert updated.context.current.input == 10
      assert_in_delta updated.spent_usd, 0.03, 0.000_001
      assert_in_delta updated.delegated_spent_usd, 0.02, 0.000_001
      assert Conversation.status(updated) =~ "$0.0300 incl. $0.0200 delegated"

      # A fan-out's tokens are the parent's bill and never the parent's
      # window: they climb the session total while the children run, and the
      # position stays the parent's own last request.
      assert updated.context.delegated == %{input: 40, output: 5, cached: 3, cache_write: 0}
      assert updated.context.tokens == 12
      assert Lemieux.Context.cumulative(updated.context) == 48
      assert Conversation.status(updated) =~ "session 48 tok"
    end

    # A child reports usage per request, so several arrive before it finishes.
    # Waiting for the result envelope was the bug: a delegation's whole cost
    # appeared at the end, and a cancelled one never appeared at all.
    test "each delegated usage event adds to the running session total" do
      usage = fn tokens -> %{"input_tokens" => tokens, "output_tokens" => 0} end

      updated =
        Enum.reduce([100, 200, 300], conversation(), fn tokens, conversation ->
          {conversation, []} =
            Conversation.event(conversation, {:subagent, ["root", "a"], {:usage, usage.(tokens)}})

          conversation
        end)

      assert Lemieux.Context.delegated_tokens(updated.context) == 600
      assert Conversation.status(updated) =~ "session 600 tok"
    end

    test "unknown delegated cost still says the total includes delegated work" do
      usage = %{"input_tokens" => 10, "output_tokens" => 2, "cost_usd" => nil}

      assert {updated, []} =
               Conversation.event(
                 conversation(),
                 {:subagent, ["root", "child"], {:usage, usage}}
               )

      assert Conversation.status(updated) =~ "cost unmeasured incl. delegated"
    end

    test "an error is described rather than inspected" do
      event = {:error, {:missing_api_key, :openai, "OPENAI_API_KEY"}}

      said = conversation() |> Conversation.event(event) |> elem(1) |> said()

      assert said =~ "OPENAI_API_KEY"
      refute said =~ "{:missing_api_key"
    end
  end

  describe "configuration events" do
    test "a model change updates the title source and can report a new unknown window once" do
      conversation = conversation(noted_window?: true)

      assert {changed, effects} =
               Conversation.event(
                 conversation,
                 {:model_changed, "test:model", "openai:gpt-5"}
               )

      assert changed.model == "openai:gpt-5"
      refute changed.noted_window?
      assert said(effects) =~ "openai:gpt-5"
    end

    test "a reasoning effort change updates the status source" do
      assert {changed, effects} =
               Conversation.event(
                 conversation(reasoning_effort: "default"),
                 {:reasoning_effort_changed, "default", "high"}
               )

      assert changed.reasoning_effort == "high"
      assert said(effects) =~ "high"
    end

    test "a persisted tool result previews its outcome" do
      entry = %{
        type: :tool_result,
        payload: %{"name" => "bash", "output" => "compiled\nmore", "error" => false}
      }

      assert {_conversation, [{:say, preview}]} =
               Conversation.event(conversation(), {:entry, entry})

      assert preview =~ "✓ bash compiled …"
    end
  end

  describe "a question from the agent" do
    test "is shown, and marks the conversation as waiting for an answer" do
      question = %{call_id: "call-1", question: "teal or red?"}

      assert {asking, effects} = Conversation.event(conversation(), {:question, question})

      assert asking.asking == "call-1"
      assert said(effects) =~ "teal or red?"
      assert {:asked, question} in effects
    end
  end

  describe "the end of a turn" do
    test "reports idle once, and is ready for another line" do
      assert {done, effects} =
               Conversation.event(conversation(busy?: true), {:finished, :stop})

      refute done.busy?
      assert :ready in effects
      assert :idle in effects
    end

    test "a cancelled turn says so" do
      assert conversation(busy?: true)
             |> Conversation.event({:finished, :cancelled})
             |> elem(1)
             |> said() =~ "cancelled"
    end

    test "a turn the session stopped on its own says which bound it hit" do
      assert conversation(busy?: true)
             |> Conversation.event({:finished, :max_turns})
             |> elem(1)
             |> said() =~ "turns"

      assert conversation(busy?: true)
             |> Conversation.event({:finished, :no_progress})
             |> elem(1)
             |> said() =~ "same answer"
    end

    test "an ordinary end of turn says nothing about why" do
      assert conversation(busy?: true)
             |> Conversation.event({:finished, :stop})
             |> elem(1)
             |> said() == ""
    end

    test "forgets a question the turn never got an answer to" do
      conversation = conversation(busy?: true, asking: "call-1")

      assert {done, _effects} = Conversation.event(conversation, {:finished, :stop})
      assert done.asking == nil
    end
  end

  describe "the context window" do
    defp context(fields), do: struct!(%Context{measured?: true}, fields)

    test "is reported by /context whenever it is asked for" do
      conversation =
        conversation(
          context:
            context(
              tokens: 6_000,
              window: 10_000,
              fraction: 0.6,
              current: %{input: 1_000, cached: 4_000, cache_write: 500, output: 500},
              spent: %{
                input: 2_000,
                output: 500,
                cached: 4_000,
                cache_write: 500,
                requests: 1
              }
            )
        )

      said = conversation |> effects("/context") |> said()

      assert said =~ "6.0k/10.0k tokens (60%)"
      assert said =~ "Context window (last measured request)"
      assert said =~ "Uncached input   1.0k tokens"
      assert said =~ "Cache read       4.0k tokens"
      assert said =~ "Cache write      500 tokens"
      assert said =~ "Model output     500 tokens"
      assert said =~ "Available        4.0k tokens"
      assert said =~ "Session total"
      assert said =~ "Requests         1"
      assert said =~ "Cost             $0.0000"
    end

    test "does not claim free capacity when the current position is unmeasured or unknown" do
      unmeasured =
        conversation(
          context: %Context{
            spent: %{input: 100, output: 20, cached: 0, cache_write: 0, requests: 1}
          }
        )
        |> effects("/context")
        |> said()

      assert unmeasured =~ "Unmeasured — new session or just compacted"
      refute unmeasured =~ "Available"
      assert unmeasured =~ "Session total"

      unknown =
        conversation(
          context: %Context{
            measured?: true,
            tokens: 120,
            current: %{input: 100, output: 20, cached: 0, cache_write: 0}
          }
        )
        |> effects("/context")
        |> said()

      assert unknown =~ "Used             120 tokens"
      refute unknown =~ "Available"
    end

    # A session that will never fill its window should not have a token count
    # printed under every answer it gives, and one that is about to fill it
    # should not have to be asked.
    test "announces itself unasked once half of it is gone" do
      conversation = conversation(busy?: true, context: context(fraction: 0.6, window: 10_000))

      assert conversation |> Conversation.event({:finished, :stop}) |> elem(1) |> said() =~ "60%"
    end

    test "and stays out of the way while there is room" do
      conversation = conversation(busy?: true, context: context(fraction: 0.1, window: 10_000))

      refute conversation |> Conversation.event({:finished, :stop}) |> elem(1) |> said() =~
               "tokens"
    end
  end

  describe "a model nothing has published limits for" do
    # The session says this itself before its first request, and knows what
    # it is planning against; this is the note for a session that did not.
    # It used to claim the session "will not compact on its own", which the
    # fallback window made false.
    test "is called out once, naming the flag that fixes it" do
      unmeasured = %Context{measured?: true, window: nil, tokens: 10}

      assert {noted, effects} = Conversation.event(conversation(), {:context, unmeasured})

      said = said(effects)
      assert said =~ "nothing publishes test:model's context window"
      assert said =~ "--context-window"
      refute said =~ "will not compact"

      # Once, not once a turn.
      assert {_noted, again} = Conversation.event(noted, {:context, unmeasured})
      assert said(again) == ""
    end

    test "and a model with a known window is never mentioned" do
      known = %Context{measured?: true, window: 10_000, tokens: 10, fraction: 0.001}

      refute conversation() |> Conversation.event({:context, known}) |> elem(1) |> said() =~
               "context window"
    end
  end

  describe "provider failures" do
    test "present typed provider errors without leaking their struct representation" do
      [error: reason] = Scripted.http_error(500, reason: "provider unavailable")

      assert Conversation.describe(reason) == "provider unavailable"

      # And says how to undo the stop, because a provider failure is the
      # one kind that a retry can.
      assert conversation()
             |> Conversation.event({:error, reason})
             |> elem(1)
             |> said() ==
               "error: test returned HTTP 500: provider unavailable · /retry to send the request again"
    end
  end

  describe "describe/1 for a refused tool switch" do
    # What a person sees after typing `/elixir` on a host that shares one
    # session between people. Naming the tools was true and left them checking
    # the allowlist, which is the one setting that did not cause either
    # refusal.
    test "names the setting behind each refusal" do
      message =
        Conversation.describe(
          {:tools_disallowed, [{"elixir", :default_off_shared}, {"ask_user", :no_human_channel}]}
        )

      assert message =~ "does not authorize tools: elixir, ask_user"
      assert message =~ "elixir — off by default where one session is shared between people"
      assert message =~ "ask_user — it needs a channel to a person"
    end

    test "an allowlist that omits the tool says so" do
      message = Conversation.describe({:tools_disallowed, [{"write", :not_allowlisted}]})

      assert message =~ "does not authorize tool: write"
      assert message =~ "allowlist does not name it"
    end
  end

  describe "a compaction's sections" do
    test "are counted on the line that reports it, and absent when there were none" do
      sections = %{
        open_work: ["a", "b"],
        dependencies: [],
        decisions: ["c"],
        verification_debt: ["d"]
      }

      {_conversation, effects} =
        Conversation.event(
          conversation(),
          {:compacted, %{entries: [1, 2, 3], sections: sections}}
        )

      assert said(effects) =~ "3 entries"
      assert said(effects) =~ "open 2 · blocked 0 · decided 1 · unverified 1"

      {_conversation, effects} =
        Conversation.event(conversation(), {:compacted, %{entries: [1, 2, 3], sections: nil}})

      assert said(effects) =~ "3 entries"
      refute said(effects) =~ "open"
    end
  end

  describe "what a compaction says it bought" do
    # An entry count measures the transcript; the reason anybody compacts is
    # the window. Before this, the only way to find out what the cut had done
    # to it was to send another request and read the status line.
    test "the last request is labelled and the next request remains unknown" do
      {conversation, effects} =
        Conversation.event(
          conversation(),
          {:compacted,
           %{entries: [1, 2, 3], sections: nil, tokens: %{before: 128_400, after: 38_200}}}
        )

      assert said(effects) =~ "3 entries"
      assert said(effects) =~ "last request 128.4k tok"
      assert Conversation.status(conversation) =~ "context ?"
    end

    test "sections and the window both fit on it" do
      sections = %{open_work: ["a"], dependencies: [], decisions: [], verification_debt: []}

      {_conversation, effects} =
        Conversation.event(
          conversation(),
          {:compacted,
           %{entries: [1], sections: sections, tokens: %{before: 9_000, after: 2_000}}}
        )

      assert said(effects) =~ "last request 9.0k tok · open 1"
    end

    # A second compaction in a row has no measurement to report, and an
    # invented one would be worse than the entry count on its own.
    test "says nothing about the window when nothing measured it" do
      {_conversation, effects} =
        Conversation.event(
          conversation(),
          {:compacted, %{entries: [1, 2, 3], sections: nil, tokens: nil}}
        )

      assert said(effects) =~ "3 entries"
      refute said(effects) =~ "context"
    end
  end

  # A host's own command, and one that takes a built-in's name.
  defmodule Wave do
    @moduledoc false
    @behaviour Lemieux.Conversation.Command

    @impl Lemieux.Conversation.Command
    def spec do
      %{
        name: "wave",
        aliases: ["hi"],
        description: "wave at the room",
        accepts_arguments?: true,
        action: {:wave, nil}
      }
    end

    @impl Lemieux.Conversation.Command
    def parse("", _conversation), do: [{:wave, nil}]
    def parse(whom, _conversation), do: [{:wave, String.trim(whom)}]

    @impl Lemieux.Conversation.Command
    def perform(acc, _host, _effect), do: acc

    @impl Lemieux.Conversation.Command
    def completions(_typed, _conversation), do: ["alice", "bob"]
  end

  defmodule HostModel do
    @moduledoc false
    @behaviour Lemieux.Conversation.Command

    @impl Lemieux.Conversation.Command
    def spec do
      %{
        name: "model",
        description: "pick from the host's catalog",
        accepts_arguments?: true,
        action: :host_model
      }
    end

    @impl Lemieux.Conversation.Command
    def parse(_spec, _conversation), do: [:host_model]

    @impl Lemieux.Conversation.Command
    def perform(acc, _host, _effect), do: acc
  end

  describe "a tool call waiting for approval" do
    defp bash_call, do: %{id: "t1", name: "bash", arguments: %{"command" => "rm -rf tmp"}}

    defp parked(fields \\ []) do
      Conversation.event(conversation([busy?: true] ++ fields), {:tool_approval, bash_call()})
    end

    defp approval_entry(status, detail \\ %{}) do
      %{
        type: :approval,
        payload: %{
          "call_id" => "t1",
          "kind" => "approval",
          "status" => status,
          "detail" => detail
        }
      }
    end

    test "is listed and shown with its arguments, and a short reply answers it" do
      {waiting, effects} = parked()

      assert [%{call_id: "t1", name: "bash", arguments: %{"command" => "rm -rf tmp"}}] =
               waiting.approvals

      assert said(effects) == "? approve bash rm -rf tmp? · y runs it · n [reason] refuses it"
      assert Enum.any?(effects, &match?({:approval, %{call_id: "t1"}}, &1))

      assert {_answered, [{:approve, "t1"}]} = Conversation.input(waiting, "y")
      assert {_answered, [{:approve, "t1"}]} = Conversation.input(waiting, "Yes")
      assert {_answered, [{:approve, "t1"}]} = Conversation.input(waiting, "allow")
      assert {_answered, [{:deny, "t1", nil}]} = Conversation.input(waiting, "n")

      assert {_answered, [{:deny, "t1", "use rg instead"}]} =
               Conversation.input(waiting, "no, use rg instead")
    end

    test "any other line is a steer, said with a reminder that the call is waiting" do
      {waiting, _effects} = parked()
      {_same, effects} = Conversation.input(waiting, "yes please be careful")

      assert {:steer, "yes please be careful"} in effects
      assert said(effects) =~ "bash is still waiting: y runs it, n [reason] refuses it"
    end

    test "the session's entry and its event list the call once, whichever arrives first" do
      detail = %{"name" => "bash", "arguments" => %{"command" => "rm -rf tmp"}}

      {from_entry, effects} =
        Conversation.event(conversation(busy?: true), {:entry, approval_entry("pending", detail)})

      assert [%{call_id: "t1", name: "bash"}] = from_entry.approvals
      assert said(effects) =~ "approve bash rm -rf tmp?"

      assert {^from_entry, []} = Conversation.event(from_entry, {:tool_approval, bash_call()})
    end

    test "a question in flight is answered ahead of it" do
      {waiting, _effects} =
        parked(asking: "q1", question: %{call_id: "q1", question: "teal or red?", options: []})

      assert {_answered, [{:answer, "q1", "y"}]} = Conversation.input(waiting, "y")
    end

    test "/approve and /deny name one when several wait" do
      {one, _effects} = parked()

      {two, effects} =
        Conversation.event(one, {:tool_approval, %{id: "t2", name: "write", arguments: %{}}})

      assert said(effects) =~ "2 waiting · /approve ID or /deny ID picks one"

      assert {_c, [{:approve, "t1"}]} = Conversation.input(two, "/approve")
      assert {_c, [{:approve, "t2"}]} = Conversation.input(two, "/approve t2")
      assert {_c, [{:approve, "t1"}, {:approve, "t2"}]} = Conversation.input(two, "/approve all")

      assert {_c, [{:deny, "t2", "not that file"}]} =
               Conversation.input(two, "/deny t2 not that file")

      assert {_c, [{:deny, "t1", "not yet"}]} = Conversation.input(two, "/deny not yet")
      assert {_c, [{:deny, "t1", nil}]} = Conversation.input(two, "/deny")

      assert {_c, [{:deny, "t1", "no"}, {:deny, "t2", "no"}]} =
               Conversation.input(two, "/deny all no")

      assert said(effects(two, "/approve t9")) =~
               "no parked call is named t9 · waiting: t1 (bash), t2 (write)"
    end

    test "with nothing parked, both say so and the prompt comes back" do
      assert said(effects(conversation(), "/approve")) == "nothing is waiting for approval"
      assert :ready in effects(conversation(), "/approve")
      assert said(effects(conversation(), "/deny because")) == "nothing is waiting for approval"
    end

    test "the decision clears it, whoever made it and however it went" do
      {waiting, _effects} = parked()

      for status <- ~w(allowed denied rewritten timed_out) do
        assert {cleared, []} = Conversation.event(waiting, {:entry, approval_entry(status)})
        assert cleared.approvals == []
      end
    end

    test "a call that was not there to answer is cleared and said" do
      {waiting, _effects} = parked()

      {cleared, effects} =
        Conversation.event(waiting, {:approval_result, "t1", {:error, :unknown_call}})

      assert cleared.approvals == []

      assert said(effects) ==
               "t1 is not waiting any more · it was answered elsewhere, or timed out"

      assert {cleared, []} = Conversation.event(waiting, {:approval_result, "t1", :ok})
      assert cleared.approvals == []
    end

    test "cancelling and the end of the turn both forget it" do
      {waiting, _effects} = parked()

      assert {cancelled, [:cancel]} = Conversation.input(waiting, "/cancel")
      assert cancelled.approvals == []

      assert {done, _effects} = Conversation.event(waiting, {:finished, :stop})
      assert done.approvals == []
    end

    test "a question answered from another host stops being the next line's business" do
      asking =
        conversation(
          busy?: true,
          asking: "q1",
          question: %{call_id: "q1", question: "teal or red?", options: []}
        )

      entry = %{
        type: :approval,
        payload: %{
          "call_id" => "q1",
          "kind" => "question",
          "status" => "answered",
          "detail" => %{"answer" => "teal"}
        }
      }

      assert {cleared, []} = Conversation.event(asking, {:entry, entry})
      assert cleared.asking == nil
      assert cleared.question == nil
      assert {:steer, "hello"} in effects(cleared, "hello")
    end

    test "/approve and /deny are listed, and are actions the host policy is shown" do
      assert Enum.any?(Conversation.commands(), &(&1.name == "approve"))
      assert Conversation.help() =~ "/deny"
      assert Conversation.command_action?({:approve, "t1"})
      assert Conversation.command_action?({:deny, "t1", nil})

      policy = fn
        {:approve, _id} -> {:deny, "approvals are answered elsewhere"}
        _action -> :allow
      end

      refute Enum.any?(Conversation.commands(policy), &(&1.name == "approve"))
    end
  end

  describe "an MCP elicitation" do
    # The shape `Lemieux.MCP` parks: an id of `CALL:KEY`, the server's prompt
    # as `Lemieux.MCP.Elicitation.question/2` words it, and no options.
    test "is a question like any other, and the typed answer goes back under its id" do
      question = %{call_id: "t1:req-1", question: "gh asks: who is asking? (name)"}

      {asking, effects} = Conversation.event(conversation(busy?: true), {:question, question})

      assert asking.asking == "t1:req-1"
      assert said(effects) == "? gh asks: who is asking? (name)"

      assert {_answered, [{:answer, "t1:req-1", "octocat"}]} =
               Conversation.input(asking, "octocat")
    end

    test "its title and requested fields are shown when the payload carries them" do
      question = %{
        call_id: "t1:req-1",
        question: "who is asking?",
        title: "GitHub",
        fields: [
          %{name: "name", type: "string", description: "Your handle"},
          %{name: "age", type: "integer"}
        ]
      }

      {_asking, effects} = Conversation.event(conversation(busy?: true), {:question, question})

      assert said(effects) ==
               "? GitHub — who is asking?\n  name · string — Your handle\n  age · integer"
    end
  end

  describe "a host's own commands" do
    defp hosted(fields \\ []),
      do: struct!(Conversation.new(model: "test:model", commands: [Wave, HostModel]), fields)

    test "are listed in help and the completion data, ahead of the built-ins" do
      assert [%{name: "wave", aliases: ["hi"]}, %{name: "model", description: description} | _] =
               Conversation.commands(hosted())

      assert description == "pick from the host's catalog"
      assert Conversation.help(hosted()) =~ ~r"/wave +wave at the room"
      refute Enum.any?(Conversation.commands(), &(&1.name == "wave"))
      refute Conversation.help() =~ "/wave"
    end

    test "parse under their name and their aliases" do
      assert {_c, [{:wave, nil}]} = Conversation.input(hosted(), "/wave")
      assert {_c, [{:wave, "alice"}]} = Conversation.input(hosted(), "/hi alice")
    end

    test "are actions the host policy is shown, under the conversation's registry" do
      assert Conversation.command_action?(hosted(), {:wave, "alice"})
      refute Conversation.command_action?({:wave, "alice"})

      policy = fn
        {:wave, _whom} -> {:deny, "no waving"}
        _action -> :allow
      end

      refute Enum.any?(Conversation.commands(hosted(), policy), &(&1.name == "wave"))
      assert Conversation.command_decision(policy, {:wave, "alice"}) == {:deny, "no waving"}
    end

    test "one that takes a built-in's name wins" do
      assert {_c, [:host_model]} = Conversation.input(hosted(), "/model haiku")
      assert Enum.count(Conversation.commands(hosted()), &(&1.name == "model")) == 1
      refute Conversation.command_action?(hosted(), {:set_model, "test:x"})
    end

    test "a module that is not a command raises at construction" do
      assert_raise ArgumentError, ~r/commands: Enum does not implement/, fn ->
        Conversation.new(commands: [Enum])
      end
    end

    test "an argument to a command that takes none is refused, not sent to the model" do
      effects = effects(conversation(), "/quit now")

      refute :quit in effects
      refute Enum.any?(effects, &match?({:prompt, _text}, &1))
      assert said(effects) == "/quit takes no argument"
    end
  end

  describe "provider failures, worded by what a person can do" do
    defp failure_line(conversation \\ conversation(), reason),
      do: conversation |> Conversation.event({:error, reason}) |> elem(1) |> said()

    # req_llm's hint names every place a key may come from, in its own
    # vocabulary; the line names the variable, and never offers /retry.
    test "a missing key names the variable to set and offers /provider, not /retry" do
      hint =
        ":api_key option, config :req_llm, zai_coding_plan_api_key, or ZAI_API_KEY env var " <>
          "(.env via dotenvy)"

      line = failure_line({:missing_api_key, "zai_coding_plan", hint})

      assert line == "no API key for zai_coding_plan · set ZAI_API_KEY, or switch with /provider"
      refute line =~ "/retry"
    end

    test "a refused key says retrying will not help" do
      [error: reason] = Scripted.http_error(401, reason: "invalid x-api-key")

      line = failure_line(conversation(model: "anthropic:claude-sonnet-5"), reason)

      assert line =~ "anthropic refused the credentials"
      assert line =~ "retrying will not help"
      refute line =~ "/retry"
    end

    # An exhausted OpenAI quota arrives as a 429, which a rate-limit reading
    # would tell somebody to wait out.
    test "an exhausted quota is a billing problem even when it arrives as a 429" do
      [error: reason] =
        Scripted.http_error(429,
          reason: "You exceeded your current quota",
          provider_code: "insufficient_quota"
        )

      line = failure_line(conversation(model: "openai:gpt-5"), reason)

      assert line =~ "openai refused for billing or quota"
      assert line =~ "retrying will not help"
      refute line =~ "/retry"
    end

    # The session declines to retry exactly the failures
    # `Lemieux.Provider.Error.account?/1` names. The line must say so for the
    # same set, and offer /retry for every other one; a second list of codes
    # kept here once let the two disagree.
    test "retrying will not help is said exactly when the provider error is an account failure" do
      request = &Request.exception/1

      reasons = [
        request.(reason: "invalid x-api-key", status: 401),
        request.(reason: "payment required", status: 402),
        request.(reason: "forbidden", status: 403),
        request.(reason: "quota", status: 429, provider_code: "insufficient_quota"),
        request.(
          reason: "limit",
          status: 400,
          response_body: %{"error" => %{"type" => "billing_hard_limit_reached"}}
        ),
        request.(
          reason: "wrapped",
          status: 400,
          cause: request.(reason: "credit", status: 400, provider_code: "credit_balance_too_low")
        ),
        request.(reason: "slow down", status: 429),
        request.(reason: "overloaded", status: 529),
        request.(reason: "server error", status: 500),
        request.(reason: "too long", status: 400, provider_code: "context_length_exceeded")
      ]

      for reason <- reasons do
        line = failure_line(reason)
        account? = ProviderError.account?(reason)

        assert String.contains?(line, "retrying will not help") == account?,
               "#{inspect(reason.status)} #{inspect(reason.provider_code)}: #{line}"

        assert String.contains?(line, "/retry") == not account?,
               "#{inspect(reason.status)} #{inspect(reason.provider_code)}: #{line}"
      end

      assert Enum.count(reasons, &ProviderError.account?/1) == 6
    end

    # Sent again, a refusal on policy grounds is usually refused again, and
    # each attempt is another flagged request on the account (#32).
    test "a policy refusal says what to change, and does not offer /retry" do
      refusal = %Lemieux.Provider.Interrupted{
        provider: "openai_codex",
        detail: "This request was flagged.",
        code: "cyber_policy"
      }

      line = failure_line(conversation(model: "openai_codex:gpt-6.1-sol"), refusal)

      assert line =~ "openai_codex refused the request"
      assert line =~ "cyber_policy"
      assert line =~ "change the request"
      refute line =~ "/retry"
    end

    test "a rate limit says how long the provider asked for" do
      [error: reason] =
        Scripted.http_error(429, reason: "slow down", headers: [{"retry-after", "30"}])

      line = failure_line(reason)

      assert line =~ "rate limited"
      assert line =~ "/retry after 30.0s"
    end

    test "a conversation that no longer fits is told to compact before retrying" do
      [error: reason] =
        Scripted.http_error(400,
          reason: "maximum context length exceeded",
          provider_code: "context_length_exceeded"
        )

      assert failure_line(reason) =~ "/compact, then /retry"
    end

    test "an automatic retry after the answer started says the partial answer is kept" do
      [error: reason] = Scripted.http_error(529, reason: "overloaded")

      retry = %{
        attempt: 2,
        max: 5,
        delay_ms: 4_000,
        category: :server,
        reason: reason,
        after_output: true
      }

      line = conversation() |> Conversation.event({:provider_retry, retry}) |> elem(1) |> said()

      assert line =~ "retrying in 4.0s (2/5)"
      assert line =~ "the partial answer is kept"
    end

    test "a locked session says where it is open and what to delete if it is not" do
      holder = %{
        host: "laptop",
        os_pid: 4242,
        since: ~U[2026-09-28 20:00:00Z],
        path: "/tmp/sessions/abc.lock"
      }

      text = Conversation.describe({:session_locked, holder})

      assert text =~ "open in another lmx (pid 4242 on laptop since 2026-09-28 20:00 UTC)"
      assert text =~ "delete /tmp/sessions/abc.lock if that process is gone"
    end

    test "an unknown context window is said once, with the size the session assumed" do
      event = {:context_window_unknown, %{model: "local:thing", fallback: 128_000}}

      {noted, effects} = Conversation.event(conversation(), event)

      assert said(effects) =~ "nothing publishes local:thing's context window"
      assert said(effects) =~ "128.0k tokens"
      assert noted.noted_window?
    end
  end

  describe "a person's own command" do
    test "!command runs it, and a bare ! says how" do
      assert [{:shell, "git status"}] = effects(conversation(), "!git status")
      assert [{:shell, "ls"}] = effects(conversation(busy?: true), "! ls ")
      assert said(effects(conversation(), "!")) =~ "type a command after !"
    end

    # A question is answered with a line; `!ls` typed under one is somebody
    # looking before they answer.
    test "!command under an open question runs rather than answering it" do
      asking = conversation(asking: "call-1", question: %{call_id: "call-1", question: "which?"})

      assert [{:shell, "ls"}] = effects(asking, "!ls")
    end

    test "is a command a host policy can refuse" do
      assert Conversation.command_action?(conversation(), {:shell, "rm -rf tmp"})
    end

    test "its output is shown, and carried ahead of the next prompt, once" do
      result = %{
        command: "git status",
        output: "On branch main\nnothing to commit\n",
        bytes: 34,
        truncated?: false,
        exit_status: 0,
        outcome: :exited
      }

      {held, shown} =
        Conversation.event(conversation(), {:shell_result, "git status", {:ok, result}})

      assert said(shown) =~ "$ git status\nOn branch main\nnothing to commit\n(exit 0)"
      assert said(shown) =~ "shared with your next message"

      {sent, [{:prompt, text}]} = Conversation.input(held, "why is it clean?")

      assert text =~ "You did not run it"
      assert text =~ "$ git status"
      assert String.ends_with?(text, "why is it clean?")

      # Spent: the next message does not carry it again.
      {_again, [{:prompt, second}]} =
        Conversation.input(%{sent | busy?: false}, "and now?")

      assert second == "and now?"
    end

    test "a steer carries it too" do
      held = Conversation.note_for_next(conversation(busy?: true), "[a note]")

      assert [{:steer, "[a note]\n\nlook at this"} | _said] = effects(held, "look at this")
    end

    test "a command that could not run says why" do
      {_conversation, effects} =
        Conversation.event(
          conversation(),
          {:shell_result, "nope", {:error, "could not run nope: :enoent"}}
        )

      assert said(effects) =~ "could not run nope"
    end
  end

  describe "prompts a command writes" do
    test "are sent as a turn, with what the command said" do
      {sending, effects} =
        Conversation.event(conversation(), {:send_prompt, "draft AGENTS.md", "asking the agent"})

      assert sending.busy?
      assert [{:say, "asking the agent"}, {:prompt, "draft AGENTS.md"}] = effects
    end

    test "arriving mid-turn, go in as a steer rather than being lost" do
      {_conversation, effects} =
        Conversation.event(conversation(busy?: true), {:send_prompt, "draft", "asking"})

      assert {:steer, "draft"} in effects
      refute Enum.any?(effects, &match?({:prompt, _text}, &1))
    end

    test "an MCP prompt typed by name is looked up when performed" do
      assert [{:mcp_prompt, "mcp__github__review", "number=42"}] =
               effects(conversation(), "/mcp__github__review number=42")

      refute Enum.any?(effects(conversation(busy?: true), "/mcp__github__review"), fn
               {:mcp_prompt, _command, _arguments} -> true
               _other -> false
             end)
    end

    test "an MCP prompt's text is sent as the person's message" do
      {_conversation, effects} =
        Conversation.event(
          conversation(),
          {:mcp_prompt_result, "mcp__github__review", {:ok, "Review PR 42"}}
        )

      assert {:prompt, "Review PR 42"} in effects
    end
  end

  describe "undoing the agent's file changes" do
    test "what was put back is said, and the model is told before the next message" do
      report = %{
        turn: 3,
        restored: ["lib/a.ex"],
        deleted: ["lib/new.ex"],
        conflicts: [%{path: "lib/b.ex", reason: "changed since the agent wrote it"}],
        unrestorable: []
      }

      {held, effects} = Conversation.event(conversation(), {:undo_result, {:ok, report}})

      line = said(effects)
      assert line =~ "undid turn 3"
      assert line =~ "restored lib/a.ex"
      assert line =~ "deleted lib/new.ex"
      assert line =~ "left alone: lib/b.ex (changed since the agent wrote it)"
      assert line =~ "/undo --force"

      {_sent, [{:prompt, text}]} = Conversation.input(held, "try again")
      assert text =~ "The person undid your file changes from turn 3"
      assert text =~ "lib/a.ex"
    end

    test "nothing to undo says what is kept" do
      {_conversation, effects} =
        Conversation.event(conversation(), {:undo_result, {:error, :nothing_to_undo}})

      assert said(effects) =~ "nothing to undo"
    end

    test "/undo and /rewind wait for the turn and read their arguments" do
      assert [{:undo, false}] = effects(conversation(), "/undo")
      assert [{:undo, true}] = effects(conversation(), "/undo --force")
      assert [{:rewind, 3, false}] = effects(conversation(), "/rewind 3")
      assert [{:rewind, 2, true}] = effects(conversation(), "/rewind --force 2")
      assert said(effects(conversation(), "/rewind")) =~ "usage: /rewind N"
      refute Enum.any?(effects(conversation(busy?: true), "/undo"), &match?({:undo, _}, &1))
    end
  end

  describe "the new commands' grammar" do
    test "/permissions reads a mode, allow and forget" do
      assert [:permissions_status] = effects(conversation(), "/permissions")

      assert [{:set_permission_mode, "accept_edits"}] =
               effects(conversation(), "/permissions accept-edits")

      assert [{:remember_permission, "Bash(mix test:*)"}] =
               effects(conversation(), "/permissions allow Bash(mix test:*)")

      assert [{:forget_permission, "Edit"}] = effects(conversation(), "/permissions forget Edit")
    end

    test "/verify and /delegate read on and off" do
      assert [:verify_status] = effects(conversation(), "/verify")
      assert [{:set_verify, true}] = effects(conversation(), "/verify on")
      assert [{:set_verify, false}] = effects(conversation(), "/verify OFF")
      assert [{:set_delegate, false}] = effects(conversation(), "/delegate off")
      assert [:delegate_status] = effects(conversation(busy?: true), "/delegate")
      refute {:set_delegate, true} in effects(conversation(busy?: true), "/delegate on")
    end

    test "/memory is personal unless --project, and bare it says where" do
      assert [{:memory, :personal, "we use tabs"}] =
               effects(conversation(), "/memory we use tabs")

      assert [{:memory, :project, "run mix precommit"}] =
               effects(conversation(), "/memory --project run mix precommit")

      assert [{:memory, :personal, ""}] = effects(conversation(), "/memory")
    end

    test "/init waits for the turn" do
      assert [:init] = effects(conversation(), "/init")
      refute :init in effects(conversation(busy?: true), "/init")
    end

    test "/resume all lists every directory's sessions" do
      assert [{:resume_list, :all}] = effects(conversation(), "/resume all")
      assert [:resume_status] = effects(conversation(), "/resume")

      assert [{:resume, "wayne-gretzky"}] =
               effects(conversation(), "/resume wayne-gretzky")
    end

    test "/diff, /export and /doctor" do
      assert [:diff] = effects(conversation(busy?: true), "/diff")
      assert [{:export, nil}] = effects(conversation(), "/export")
      assert [{:export, "notes/run.md"}] = effects(conversation(), "/export notes/run.md")
      assert [:doctor] = effects(conversation(), "/doctor")
    end
  end

  describe "/help" do
    # Everyday commands first: a menu that opened on /reflect taught people it
    # was the command to reach for.
    test "lists everyday commands before the research ones" do
      names = Enum.map(Conversation.commands(), & &1.name)

      assert Enum.take(names, 3) == ["model", "provider", "effort"]
      assert index(names, "undo") < index(names, "reflect")
      assert index(names, "diff") < index(names, "feedback")
    end

    test "says how to run a command of your own" do
      assert Conversation.help() =~ "!command runs a shell command"
    end

    defp index(names, name), do: Enum.find_index(names, &(&1 == name))
  end
end

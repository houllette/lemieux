defmodule Lemieux.Live.ProvidersTest do
  @moduledoc """
  The whole loop, against every provider lemieux claims to support.

  These are the tests behind the promise that nothing in lemieux is written for
  Anthropic. They drive a real session — prompt, tool call, tool result, answer
  — rather than a bare provider call, because the parts that break across
  providers are the ones between: whether a streamed tool call arrives
  assembled, whether an assistant turn replays in a shape the provider accepts,
  whether usage comes back at all.

  `@tag :live` and excluded by default. Adding a provider is one row in
  `@providers`, which is the point: if adding one needed anything else, the
  claim would not be true.

  A provider with no key exported **skips** rather than fails. A red suite that
  means "you did not export a key" is one people learn to ignore, and these run
  on whichever keys the person running them happens to hold.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Provider
  alias Lemieux.Providers.ReqLLM, as: ReqLLMProvider
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools

  @moduletag :live
  # Skipped even when chosen by `path:LINE`, which beats the `:live` exclude,
  # unless the run allows spending: see `LemieuxTest.Spend.skip/0`. The
  # Ollama row would otherwise prompt a local server's model unasked.
  @moduletag skip: LemieuxTest.Spend.skip()
  @moduletag :tmp_dir
  @moduletag timeout: :timer.minutes(2)

  # One row per provider. The hosted models are the cheapest each vendor offers
  # that can still call a tool: this suite is run by hand and should not be a
  # reason to think twice about it.
  #
  # Ollama is available by a server being up rather than a key being exported,
  # which is the whole difference a local provider makes — see `available?/1`.
  @providers [
    %{
      name: "zai_coding_plan",
      model: "zai_coding_plan:glm-5.3",
      key: "ZAI_API_KEY"
    },
    %{name: "anthropic", model: "anthropic:claude-haiku-4-5", key: "ANTHROPIC_API_KEY"},
    %{name: "openai", model: "openai:gpt-4o-mini", key: "OPENAI_API_KEY"},
    %{name: "google", model: "google:gemini-2.5-flash", key: "GOOGLE_API_KEY"},
    %{name: "ollama", model: :discover, url: "http://localhost:11434/api/tags"}
  ]

  setup %{tmp_dir: tmp_dir} do
    {:ok, _apps} = Application.ensure_all_started(:req_llm)

    runtime = :"lemieux_live_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    File.write!(Path.join(tmp_dir, "secret.txt"), "the codeword is marmalade\n")

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp start(context, provider) do
    {:ok, session} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: configured_provider(provider),
        store: context.store,
        model: model_for(provider),
        subscriber: self(),
        cwd: context.tmp_dir,
        tools: Tools.default(),
        params: [max_tokens: 1024],
        max_turns: 6
      )

    session
  end

  defp configured_provider(_provider), do: ReqLLMProvider.new()

  # A provider is available when whatever it needs is there: a key for a hosted
  # one, a server for a local one. Neither is a failure — these run on whatever
  # the person running them happens to have.
  defp available?(%{key: key}) do
    case System.get_env(key) do
      value when is_binary(value) and value != "" -> true
      _otherwise -> false
    end
  end

  defp available?(%{url: url}) do
    match?({:ok, %{status: 200}}, Req.get(url, retry: false, receive_timeout: 2_000))
  rescue
    _error -> false
  end

  defp missing(%{key: key}), do: "#{key} is not exported"
  defp missing(%{url: url}), do: "nothing is answering at #{url}"

  # Which local model to use is a property of the machine, not of lemieux:
  # whoever is running this pulled whatever they pulled. `LMX_OLLAMA_MODEL`
  # names one, and otherwise the first the server reports is as good a choice
  # as this suite can make.
  defp model_for(%{model: :discover}) do
    case System.get_env("LMX_OLLAMA_MODEL") do
      name when is_binary(name) and name != "" -> "ollama:" <> name
      _otherwise -> "ollama:" <> first_installed()
    end
  end

  defp model_for(%{model: model}), do: model

  defp first_installed do
    %{status: 200, body: %{"models" => [%{"name" => name} | _rest]}} =
      Req.get!("http://localhost:11434/api/tags", retry: false)

    name
  end

  for provider <- @providers do
    @provider provider

    describe "#{provider.name}" do
      @describetag provider: provider.name

      test "runs a whole turn: prompt, tool call, tool result, answer", context do
        if available?(@provider) == false do
          # Not an assertion: the point is that an absent provider is not a
          # failure.
          IO.puts("  skipped #{@provider.name}: #{missing(@provider)}")
        else
          session = start(context, @provider)
          id = Session.id(session)

          :ok =
            Session.prompt(
              session,
              "Read the file secret.txt in the current directory and tell me the codeword. " <>
                "Answer with the codeword and nothing else."
            )

          assert_receive {:lemieux, ^id, {:finished, reason}}, :timer.seconds(90)

          # A live failure is usually about the account rather than the code —
          # no credit, a quota, a key for the wrong organisation — so whatever
          # the provider said is put in front of whoever is reading the failure
          # instead of leaving them with a bare stop reason.
          assert reason in [:stop, :end_turn], "#{@provider.name} did not finish: #{why(reason)}"

          entries = Session.snapshot(session).entries

          text =
            entries
            |> Enum.filter(&(&1.type == :assistant))
            |> Enum.map_join(" ", &assistant_text/1)

          # A tool ran, through lemieux's own dispatch — but *which* one is the
          # model's business. Asserting `read` here failed against a local
          # model that reached for `bash` and `cat` instead, which is a
          # perfectly good way to read a file and no evidence of anything
          # wrong.
          assert Enum.any?(entries, &(&1.type == :tool_result)),
                 "#{@provider.name} used no tools; it said: #{inspect(text)}"

          # And the model read what the tool returned.
          tool_results =
            entries
            |> Enum.filter(&(&1.type == :tool_result))
            |> Enum.map(& &1.payload)

          assert text =~ ~r/marmalade/i,
                 "#{@provider.name} ignored its tool results #{inspect(tool_results)}; " <>
                   "it said: #{inspect(text)}"
        end
      end

      test "reports usage and knows its own context window", context do
        if available?(@provider) == false do
          IO.puts("  skipped #{@provider.name}: #{missing(@provider)}")
        else
          session = start(context, @provider)
          id = Session.id(session)

          :ok = Session.prompt(session, "Say the word ready and nothing else.")
          assert_receive {:lemieux, ^id, {:finished, _reason}}, :timer.seconds(60)

          snapshot = Session.snapshot(session)

          # Accounting is not optional: without it there is no compaction, and
          # a provider that reports nothing would fill its window in silence.
          assert snapshot.context.measured?,
                 "#{@provider.name} reported no usage: #{why(:no_usage)}"

          assert snapshot.context.tokens > 0
          assert snapshot.context.spent.requests >= 1

          # The window is whatever the model database knows, and for a locally
          # served model that is nothing — nobody published a datasheet for the
          # quantisation you pulled. Asserted as the rule rather than as a
          # number, so a local provider is held to the truth about itself: no
          # window means no threshold compaction, which is documented on
          # `Lemieux.Context` and is why `--context-window` exists.
          case Provider.context_window(ReqLLMProvider.new(), model_for(@provider)) do
            nil ->
              assert snapshot.context.window == nil
              assert snapshot.context.fraction == nil

            window ->
              assert snapshot.context.window == window
              assert snapshot.context.fraction > 0.0
          end
        end
      end
    end
  end

  describe "a transcript that outlives its model" do
    @tag timeout: :timer.minutes(3)
    test "is resumed against a different provider", context do
      first = Enum.find(@providers, &available?/1)
      second = Enum.find(@providers, &(&1 != first and available?(&1)))

      if is_nil(second) do
        IO.puts("  skipped: this needs two providers to be available")
      else
        session = start(context, first)
        id = Session.id(session)

        :ok = Session.prompt(session, "Remember the number 41. Say ok and nothing else.")
        assert_receive {:lemieux, ^id, {:finished, _reason}}, :timer.seconds(60)

        :ok =
          DynamicSupervisor.terminate_child(
            Lemieux.Supervisor.session_supervisor(context.runtime),
            session
          )

        # The capability check earns its keep here: a conversation the first
        # model may have thought its way through is about to be sent to one
        # that may have no concept of thinking.
        {:ok, resumed} =
          Lemieux.resume_session(
            supervisor: context.runtime,
            provider: configured_provider(second),
            store: context.store,
            subscriber: self(),
            model: model_for(second),
            resume: id,
            params: [max_tokens: 256]
          )

        :ok = Session.prompt(resumed, "What number did I ask you to remember? Digits only.")
        assert_receive {:lemieux, ^id, {:finished, _reason}}, :timer.seconds(60)

        text =
          resumed
          |> Session.snapshot()
          |> Map.fetch!(:entries)
          |> Enum.filter(&(&1.type == :assistant))
          |> Enum.map_join(" ", &assistant_text/1)

        assert text =~ "41"
      end
    end
  end

  # Drains any error the session emitted, so a failing assertion can name the
  # provider's own words rather than the symptom.
  defp why(reason) do
    receive do
      {:lemieux, _id, {:error, error}} -> inspect(error)
    after
      0 -> "finished #{inspect(reason)} with nothing further to say"
    end
  end

  defp assistant_text(%Entry{payload: %{"content" => parts}}) when is_list(parts) do
    parts
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join(" ", &Map.get(&1, "text", ""))
  end

  defp assistant_text(%Entry{}), do: ""
end

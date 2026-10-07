defmodule LemieuxJevCompaction.LocalServerTest do
  # Scores a read through a System One server you started yourself, over the
  # real wire: the check that a scorer on your own machine is a provider like
  # any other. It runs only when `LOCAL_SYSTEM_ONE_URL` names the server
  # (test/test_helper.exs excludes it otherwise), with
  # `LOCAL_SYSTEM_ONE_MODEL` naming the model to ask and, if the server wants
  # one, `LOCAL_SYSTEM_ONE_KEY` the bearer token. Two servers it has been run
  # against (2026-10):
  #
  #     ollama pull nimble            # Ollama 0.35+ serves /v1/systemone
  #     LOCAL_SYSTEM_ONE_URL=http://127.0.0.1:11434 LOCAL_SYSTEM_ONE_MODEL=nimble \
  #       mix test test/jev_compaction/local_server_test.exs
  #
  #     npx laya-system-one --host 127.0.0.1 --port 8080
  #     LOCAL_SYSTEM_ONE_URL=http://127.0.0.1:8080 LOCAL_SYSTEM_ONE_MODEL=laya-multilingual \
  #       mix test test/jev_compaction/local_server_test.exs
  #
  # A model's verdict on the fixture is its own, so the test asserts the
  # shape of the evaluation — one attempt, a probability in [0, 1], the usage
  # record naming the model, the budget charged at the declared zero rate —
  # and prints the verdict rather than asserting it.
  use ExUnit.Case, async: false

  alias Lemieux.{Entry, Request, Session}
  alias Lemieux.Store.JSONL
  alias LemieuxJevCompaction, as: JevCompaction

  @moduletag :local_system_one
  @moduletag :tmp_dir

  test "a locally served decision model scores an old read over the real wire", %{tmp_dir: dir} do
    url = System.fetch_env!("LOCAL_SYSTEM_ONE_URL")
    model = System.fetch_env!("LOCAL_SYSTEM_ONE_MODEL")

    runtime = :"jev_local_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Lemieux.Providers.Scripted.new([]),
        store: JSONL.new(dir),
        model: "test:model",
        max_cost_usd: 0.01,
        tools: [Lemieux.Tools.Read]
      )

    output =
      Enum.map_join(1..120, "\n", fn n ->
        "defp helper_#{n}(value), do: value + #{n}  # an old implementation, since rewritten"
      end)

    request = request(output)

    opts = [
      provider: %{
        name: "local",
        type: :endpoint,
        base_url: url,
        api_key: System.get_env("LOCAL_SYSTEM_ONE_KEY"),
        api_key_header: nil,
        headers: %{},
        model: model
      },
      preserve_recent_entries: 0,
      # A declared tariff of zero: the session is capped, so an unpriced
      # provider would be skipped, which is the fail-closed rule under test
      # elsewhere; here the point is the wire.
      input_per_million: 0.0,
      output_per_million: 0.0,
      reservation_per_call_usd: 0.001,
      timeout_ms: 120_000
    ]

    assert {:ok, projected} = JevCompaction.prepare(request, %{session: session}, opts)
    assert {:ok, %{value: document}} = Session.document(session, "jev_compaction")

    assert document["attempts"] == 1
    assert document["last_outcome"] in ["applied", "insufficient"], inspect(document)
    assert document["last_usage"]["model"] == model

    assert [%{"candidates" => [%{"keep_probability" => probability}]}] = document["evaluations"]
    assert is_number(probability) and probability >= 0 and probability <= 1
    assert Session.budget(session).spent_usd == 0.0

    verdict =
      if document["last_outcome"] == "applied",
        do: "shortened the old read",
        else: "kept the old read"

    # The read result is the third entry, not the last: the fixture ends on
    # later turns so the result is old enough to be a candidate.
    projected_output =
      Enum.find(projected.entries, &(&1.type == :tool_result)).payload["output"]

    assert document["last_outcome"] == "applied" == (projected_output != output)

    IO.puts(
      "\n#{model} at #{url}: keep probability #{Float.round(probability / 1, 3)}, #{verdict} " <>
        "in #{document["last_latency_ms"]} ms, usage #{inspect(document["last_usage"])}"
    )
  end

  defp request(output) do
    user = Entry.new(:user, %{"text" => "Replace helper_1 through helper_120 with one function"})

    assistant =
      Entry.new(:assistant, %{
        "content" => [],
        "tool_calls" => [
          %{"id" => "call-1", "name" => "read", "arguments" => %{"path" => "lib/helpers.ex"}}
        ]
      })

    result =
      Entry.new(:tool_result, %{
        "call_id" => "call-1",
        "name" => "read",
        "arguments" => %{"path" => "lib/helpers.ex"},
        "output" => output,
        "error" => false
      })

    done = Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "Rewritten."}]})
    next = Entry.new(:user, %{"text" => "Now add tests for the new function"})

    %Request{
      model: "test:model",
      entries: [user, assistant, result, done, next],
      tools: [Lemieux.Tools.Read]
    }
  end
end

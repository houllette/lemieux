defmodule Lemieux.ResearchTranscriptCompatibilityTest do
  use ExUnit.Case, async: true

  alias Lemieux.{Context, Entry, Session}
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  # Deliberately literal historical wire data, not produced by today's writer.
  @history ~S"""
  {"v":3,"id":"config","seq":1,"type":"session","at":"2026-09-14T00:00:00Z","payload":{"model":"test:model","system":"Keep the user's decisions"},"meta":{}}
  {"v":3,"id":"user","seq":2,"type":"user","at":"2026-09-14T00:00:01Z","payload":{"text":"Remember teal"},"meta":{}}
  {"v":3,"id":"answer","seq":3,"type":"assistant","at":"2026-09-14T00:00:02Z","payload":{"content":[{"type":"text","text":"Teal noted"}]},"usage":{"input_tokens":10,"output_tokens":2},"meta":{}}
  {"v":3,"id":"guide","seq":4,"type":"guidance","at":"2026-09-14T00:00:03Z","payload":{"text":"ARCHIVED ADVICE MUST NOT ENTER THE CONVERSATION"},"usage":{"input_tokens":9000,"output_tokens":100},"meta":{}}
  """

  test "historical version-three entries retain their identity and usage" do
    entries = history()
    assert Enum.all?(entries, &(&1.v == 3))
    assert Enum.map(entries, & &1.id) == ["config", "user", "answer", "guide"]
    assert entries == Enum.map(entries, &(Entry.encode!(&1) |> Entry.decode!()))
    assert Entry.new(:user, %{"text" => "new"}).v == 2

    context = Context.position(entries, window: 20_000)
    assert context.tokens == 12
    assert context.spent.requests == 2
    assert context.spent.input == 9010
  end

  test "a research transcript resumes without activating or replaying archived advice", context do
    name = :"research_resume_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: name})
    File.write!(Path.join(context.tmp_dir, "legacy.jsonl"), @history)
    provider = Scripted.new([Scripted.complete("Still teal")])

    assert {:ok, session} =
             Lemieux.resume_session(
               supervisor: name,
               provider: provider,
               store: JSONL.new(context.tmp_dir),
               resume: "legacy",
               subscriber: self()
             )

    assert Session.snapshot(session).context.tokens == 12
    :ok = Session.prompt(session, "Continue")
    assert_receive {:lemieux, "legacy", {:finished, :stop}}
    assert [request] = Scripted.requests(provider)
    refute Enum.any?(request.entries, &(&1.type == :guidance))
    assert Enum.any?(request.entries, &(&1.id == "answer"))
    refute (request.system || "") =~ "ARCHIVED ADVICE"
    entries = Session.snapshot(session).entries
    assert Enum.take(entries, 4) == history()
    assert List.last(entries).v == 2
  end

  defp history, do: @history |> String.split("\n", trim: true) |> Enum.map(&Entry.decode!/1)
end

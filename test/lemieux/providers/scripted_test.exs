defmodule Lemieux.Providers.ScriptedTest do
  use ExUnit.Case, async: true

  alias Lemieux.Provider
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Provider.Interrupted
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request

  defp collect(provider, request) do
    parent = self()
    :ok = Provider.run(provider, request, &send(parent, {:event, &1}))

    drain([])
  end

  defp drain(acc) do
    receive do
      {:event, event} -> drain([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "replays its script in order" do
    provider = Scripted.new([[{:text_delta, "hi"}, {:done, :stop}]])

    assert collect(provider, Request.new("test:model")) == [{:text_delta, "hi"}, {:done, :stop}]
  end

  test "replays a different turn per request" do
    provider =
      Scripted.new([
        [{:text_delta, "first"}, {:done, :stop}],
        [{:text_delta, "second"}, {:done, :stop}]
      ])

    assert collect(provider, Request.new("test:model")) == [
             {:text_delta, "first"},
             {:done, :stop}
           ]

    assert collect(provider, Request.new("test:model")) == [
             {:text_delta, "second"},
             {:done, :stop}
           ]
  end

  test "records the requests it received, in order" do
    provider = Scripted.new([[{:done, :stop}], [{:done, :stop}]])
    first = Request.new("test:model", system: "one")
    second = Request.new("test:model", system: "two")

    collect(provider, first)
    collect(provider, second)

    assert Scripted.requests(provider) == [first, second]
  end

  test "a turn can be a function of the request it answers" do
    provider =
      Scripted.new([
        fn %Request{system: system} -> [{:text_delta, system}, {:done, :stop}] end
      ])

    assert collect(provider, Request.new("test:model", system: "echoed")) ==
             [{:text_delta, "echoed"}, {:done, :stop}]
  end

  test "running past the end of the script is a loud error rather than silence" do
    provider = Scripted.new([[{:done, :stop}]])
    collect(provider, Request.new("test:model"))

    assert [{:error, {:scripted, :script_exhausted, 2}}] =
             collect(provider, Request.new("test:model"))
  end

  test "requests/1 on an untouched provider is empty" do
    assert Scripted.requests(Scripted.new([])) == []
  end

  test "builders cover fragmented text, thinking, multiple calls, and typed errors" do
    assert Scripted.complete("hello", fragments: ["he", "llo"]) == [
             {:text_delta, "he"},
             {:text_delta, "llo"},
             {:done, :stop}
           ]

    assert [{:thinking_delta, "hmm"}, {:text_delta, "done"}, {:done, :stop}] =
             Scripted.thinking("hmm", "done")

    assert [
             {:tool_call, %{id: "1"}},
             {:tool_call, %{id: "2"}},
             {:done, :tool_calls}
           ] =
             Scripted.tool_calls([
               %{id: "1", name: "read", arguments: %{}},
               %{id: "2", name: "read", arguments: %{}}
             ])

    assert [{:error, %ReqLLM.Error.API.Request{status: 429}}] =
             Scripted.http_error(429, headers: %{"retry-after" => "2"})
  end

  test "a delay happens inside the provider task before later events" do
    provider = Scripted.new([Scripted.delayed(20, Scripted.complete("late"))])
    started = System.monotonic_time(:millisecond)

    assert collect(provider, Request.new("test:model")) == [
             {:text_delta, "late"},
             {:done, :stop}
           ]

    assert System.monotonic_time(:millisecond) - started >= 15
  end

  test "invalid_tool_call carries the decode cause into the normalized event" do
    assert [
             {:tool_call, %{arguments: %{}, argument_error: reason}},
             {:done, :tool_calls}
           ] = Scripted.invalid_tool_call("1", "read", ~s({"path":))

    refute is_nil(reason)
  end

  test "interrupted is what the adapter emits when a stream breaks off after output" do
    assert [
             {:text_delta, "Half "},
             {:text_delta, "an ans"},
             {:message, %{"content" => [%{"text" => "Half an ans"}], "partial" => true}},
             {:usage, %{"input_tokens" => 12}},
             {:error, %Interrupted{detail: "Overloaded"} = reason}
           ] =
             Scripted.interrupted("Half an ans",
               fragments: ["Half ", "an ans"],
               usage: %{"input_tokens" => 12},
               detail: "Overloaded"
             )

    assert ProviderError.category(reason) == :server
    assert ProviderError.transient?(reason)
  end

  test "stated_context_limit is a recognised overflow that states its window" do
    assert [{:error, reason}] = Scripted.stated_context_limit(200_000, tokens: 213_462)

    assert ProviderError.context_limit?(reason)
    assert ProviderError.stated_context_window(reason) == 200_000
    assert ProviderError.message(reason) =~ "213462 tokens > 200000 maximum"
  end
end

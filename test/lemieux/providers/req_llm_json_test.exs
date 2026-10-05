defmodule Lemieux.Providers.ReqLLMJSONTest do
  use ExUnit.Case, async: true

  alias Lemieux.{Entry, Request}
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias LemieuxTest.HTTPFixture

  test "public JSON survives object assembly on native and compatible transports" do
    for route <- [:native, :compatible] do
      events = run(~s({"answer":"teal"}), route)
      assert {:message, message} = List.keyfind(events, :message, 0)

      assert [%{"type" => "text", "text" => text}] =
               Enum.filter(message["content"], &(&1["type"] == "text"))

      assert JSON.decode!(text) == %{"answer" => "teal"}
      assert {:done, :stop} in events
    end
  end

  test "malformed public JSON stays literal and reasoning cannot replace an empty answer" do
    text = "{broken\n``"
    events = run(text, :native)
    assert {:message, message} = List.keyfind(events, :message, 0)
    assert %{"type" => "text", "text" => text} in message["content"]

    events = run("", :native)
    assert {:message, empty} = List.keyfind(events, :message, 0)
    refute Enum.any?(empty["content"], &(&1["type"] == "text" and &1["text"] != ""))
  end

  defp run(text, route) do
    owner = self()
    ref = make_ref()

    {url, listener, server} =
      HTTPFixture.server(fn _, _, _ ->
        chunks = [
          %{
            choices: [
              %{
                index: 0,
                delta: %{reasoning_content: "private fixture reasoning"},
                finish_reason: nil
              }
            ]
          },
          %{choices: [%{index: 0, delta: %{content: text}, finish_reason: nil}]},
          %{
            choices: [%{index: 0, delta: %{}, finish_reason: "stop"}],
            usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
          }
        ]

        body = Enum.map_join(chunks, "", &("data: " <> JSON.encode!(&1) <> "\n\n"))

        %{
          status: 200,
          headers: [{"content-type", "text/event-stream"}],
          body: body <> "data: [DONE]\n\n"
        }
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    options = [api_keys: %{"zai_coding_plan" => "fixture-key"}, base_url: url, max_retries: 0]

    options =
      if route == :compatible,
        do:
          Keyword.put(options, :transport_routes, %{
            "zai_coding_plan" => [provider: "mistral", base_url: url]
          }),
        else: options

    {Adapter, provider} = Adapter.new(options)

    request =
      Request.new("zai_coding_plan:glm-4.7",
        entries: [Entry.new(:user, %{"text" => "Return JSON"}, seq: 1)]
      )

    Adapter.run(provider, request, &send(owner, {ref, &1}))
    drain(ref, [])
  end

  defp drain(ref, events) do
    receive do
      {^ref, event} -> drain(ref, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end

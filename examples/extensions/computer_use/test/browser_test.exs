defmodule LemieuxComputerUse.BrowserTest do
  use ExUnit.Case, async: false
  @moduletag :browser

  setup_all do
    assert :ok = LemieuxComputerUse.Wallaby.start()
    :ok
  end

  setup do
    {:ok, server, url} = LemieuxComputerUse.Fixture.start()
    on_exit(fn -> LemieuxComputerUse.Fixture.stop(server) end)

    {:ok, session} =
      LemieuxComputerUse.Wallaby.open(String.replace(url, "index.html", "hotels.html"), [])

    on_exit(fn -> LemieuxComputerUse.Wallaby.close(session) end)
    %{session: session, url: url}
  end

  test "native input, selection, checkbox and dynamic results", %{session: session} do
    action(session, "TYPE_TEXT", "Destination", "Lisbon")
    action(session, "SELECT", "Style → Design")
    action(session, "CLICK", "Free cancellation")
    action(session, "CLICK", "Search hotels")
    # Wallaby's own bounded query waits for the actual condition, not a sleep.
    Wallaby.Browser.find(session, Wallaby.Query.button("Open Casa Flora"))
    action(session, "CLICK", "Open Casa Flora")
    assert {:ok, page} = LemieuxComputerUse.Wallaby.observe(session)
    assert LemieuxComputerUse.Fixture.verified?(page)
  end

  test "a replaced or covered target is rejected before input", %{session: session} do
    assert {:ok, page} = LemieuxComputerUse.Wallaby.observe(session)
    target = Enum.find(page["actions"], &(&1["label"] == "Search hotels"))

    Wallaby.Browser.execute_script(
      session,
      "document.querySelector('button').outerHTML='<button>Search hotels</button>'"
    )

    assert {:error, :stale} = LemieuxComputerUse.Wallaby.act(session, page, target, nil)
    assert {:ok, page} = LemieuxComputerUse.Wallaby.observe(session)
    target = Enum.find(page["actions"], &(&1["label"] == "Search hotels"))

    Wallaby.Browser.execute_script(
      session,
      "document.body.insertAdjacentHTML('beforeend','<div style=\"position:fixed;inset:0;z-index:999;background:white\">overlay</div>')"
    )

    assert {:error, :stale} = LemieuxComputerUse.Wallaby.act(session, page, target, nil)
  end

  @tag :capture_log
  test "cancelling the invoking task reclaims the real browser session", %{url: url} do
    owner = self()

    runner =
      Task.async(fn ->
        LemieuxComputerUse.Runner.run(%{"url" => url, "goal" => "Find a hotel"},
          allowed_hosts: ["127.0.0.1"],
          unsafe_allow_loopback_for_tests: true,
          crawl_pages: 0,
          classify: fn _ ->
            send(owner, {:classifying, self()})

            receive do
              :never -> {:error, "unreachable"}
            end
          end
        )
      end)

    assert_receive {:classifying, worker}, 5000
    assert [_session] = Wallaby.SessionStore.list_sessions_for(owner_pid: worker)
    ref = make_ref()

    :ok =
      :sys.install(
        Wallaby.SessionStore,
        {ref,
         fn state, event, _ ->
           case event do
             {:in, {:DOWN, _, :process, ^worker, _}} -> send(owner, :browser_owner_down)
             _ -> :ok
           end

           state
         end, nil}
      )

    on_exit(fn -> :sys.remove(Wallaby.SessionStore, ref) end)
    Task.shutdown(runner, :brutal_kill)
    assert_receive :browser_owner_down, 5000
    # A GenServer state read fences completion of its DOWN handler, which
    # deletes the WebDriver session before removing the ownership record.
    :sys.get_state(Wallaby.SessionStore)
    assert Wallaby.SessionStore.list_sessions_for(owner_pid: worker) == []
  end

  defp action(session, operation, label, text \\ nil) do
    assert {:ok, page} = LemieuxComputerUse.Wallaby.observe(session)
    target = Enum.find(page["actions"], &(&1["operation"] == operation and &1["label"] == label))
    assert target, "missing #{operation} #{label} in #{inspect(page["actions"])}"
    assert :ok = LemieuxComputerUse.Wallaby.act(session, page, target, text)
  end

  test "HTTP JavaScript shell becomes bounded whole-page text through the real browser", %{
    url: start
  } do
    url = String.replace(start, "index.html", "rendered.html")

    fetch =
      LemieuxComputerUse.Fetch.new(
        Lemieux.Tools.WebFetch.new(unsafe_allow_loopback_for_tests: true),
        allowed_hosts: ["127.0.0.1"],
        unsafe_allow_loopback_for_tests: true
      )

    {:ok, result} =
      LemieuxComputerUse.Fetch.run(fetch, %{"url" => url}, %{
        hooks: [],
        tool_output_bytes: 100_000
      })

    assert result.structured_content["source"] == "browser"
    assert result.structured_content["text"] =~ "Hydrated guide"
    assert result.structured_content["text"] =~ "Content below the viewport"
    assert result.structured_content["text"] =~ "if true do\n  :ok\nend"
    refute result.structured_content["text"] =~ "Hidden secret"
    refute result.structured_content["text"] =~ "Site navigation"

    assert result.structured_content["links"] == [
             String.replace(start, "index.html", "help.html")
           ]

    assert result.structured_content["rendered_bytes"] <= fetch.http.max_body_bytes
  end

  test "rendered projection caps a single oversized Unicode text node", %{session: session} do
    Wallaby.Browser.execute_script(
      session,
      "document.body.innerHTML='<main>'+ 'é'.repeat(10000) + '</main>'"
    )

    assert {:ok, document} = LemieuxComputerUse.Wallaby.document(session, max_bytes: 1024)
    assert byte_size(document["html"]) <= 1024
    assert String.valid?(document["html"])
    assert document["truncated"]
    assert document["html"] =~ "ééé"
  end
end

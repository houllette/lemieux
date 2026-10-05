defmodule Lemieux.CLI.UpdateCheckTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.UpdateCheck

  # A checkout updates through Git, on request: a Hex notice would point it
  # at the wrong way to update, and asking at every start would contact
  # hex.pm on each launch of a development tree.
  test "a source host never asks Hex, and keeps explicit Git installation" do
    tasks = start_supervised!(Task.Supervisor)
    get = fn _, _ -> flunk("a source checkout must not poll Hex") end

    for opts <- [[check_updates: true, get: get], [get: get]] do
      host = UpdateCheck.host(tasks, opts)
      refute host.check?
      refute host.auto?
      assert host.install?
      assert host.check.() == :current
    end
  end

  test "asks Hex for the latest stable Lemieux release with a bounded request" do
    owner = self()

    get = fn url, opts ->
      send(owner, {:request, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "name" => "lemieux",
           "repository" => "hexpm",
           "meta" => %{"links" => %{"GitHub" => "https://github.com/houllette/lemieux"}},
           "latest_stable_version" => "0.2.0"
         }
       }}
    end

    assert UpdateCheck.fetch(get: get) == {:ok, "0.2.0"}
    assert_received {:request, "https://hex.pm/api/packages/lemieux", opts}
    assert {"user-agent", "lemieux/#{Lemieux.version()}"} in opts[:headers]
    assert {"accept", "application/json"} in opts[:headers]
    assert opts[:retry] == false
    assert opts[:connect_options][:timeout] <= opts[:receive_timeout]
  end

  test "only a newer stable version produces a startup notice" do
    assert UpdateCheck.upgrade_notice("0.1.0", "0.2.0") ==
             "Lemieux v0.2.0 is available (running v0.1.0); see https://hex.pm/packages/lemieux"

    assert UpdateCheck.upgrade_notice("0.2.0-rc.1", "0.2.0") =~ "v0.2.0 is available"
    assert UpdateCheck.upgrade_notice("0.2.0", "0.2.0") == nil
    assert UpdateCheck.upgrade_notice("0.3.0", "0.2.0") == nil
    assert UpdateCheck.upgrade_notice("0.1.0", "0.2.0-rc.1") == nil
    assert UpdateCheck.upgrade_notice("invalid", "0.2.0") == nil
    assert UpdateCheck.upgrade_notice("0.1.0", "invalid") == nil
  end

  test "missing, unavailable, or malformed package data stays quiet" do
    for response <- [
          {:ok, %Req.Response{status: 404, body: %{}}},
          {:error, :timeout},
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "name" => "lemieux",
               "repository" => "hexpm",
               "meta" => %{"links" => %{"GitHub" => "https://github.com/houllette/lemieux"}},
               "latest_version" => "0.3.0-rc.1"
             }
           }},
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "name" => "lemieux",
               "repository" => "hexpm",
               "meta" => %{"links" => %{"GitHub" => "https://example.com/someone-else"}},
               "latest_stable_version" => "9.0.0"
             }
           }}
        ] do
      assert UpdateCheck.check(get: fn _, _ -> response end) == nil
    end

    assert UpdateCheck.check(get: fn _, _ -> raise "network failed" end) == nil
  end

  test "the successful lookup becomes a notice for the installed version" do
    get = fn _, _ ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "name" => "lemieux",
           "repository" => "hexpm",
           "meta" => %{"links" => %{"GitHub" => "https://github.com/houllette/lemieux"}},
           "latest_stable_version" => "999.0.0"
         }
       }}
    end

    assert UpdateCheck.check(get: get) =~ "Lemieux v999.0.0 is available"
  end

  test "an embedding host can disable the check" do
    refute UpdateCheck.enabled?(check_updates: false)
    assert UpdateCheck.enabled?(check_updates: true)
  end

  test "the background check delivers a newer release after the TUI has opened" do
    supervisor = start_supervised!(Task.Supervisor)
    owner = self()

    get = fn _, _ ->
      send(owner, {:request_started, self()})

      receive do
        :finish_request ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "name" => "lemieux",
               "repository" => "hexpm",
               "meta" => %{"links" => %{"GitHub" => "https://github.com/houllette/lemieux"}},
               "latest_stable_version" => "999.0.0"
             }
           }}
      end
    end

    assert :ok = UpdateCheck.notify(self(), supervisor, check_updates: true, get: get)
    assert_receive {:request_started, task}
    send(task, :finish_request)
    assert_receive {:version_notice, "Lemieux v999.0.0 is available" <> _rest}

    assert :ok =
             UpdateCheck.notify(self(), supervisor,
               check_updates: false,
               get: fn _, _ -> send(owner, :unexpected_request) end
             )

    refute_receive :unexpected_request, 50
  end
end

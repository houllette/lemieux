defmodule Lemieux.CLI.OAuthTest do
  @moduledoc """
  `lmx`'s half of the authorization flow: a real loopback listener on a real
  socket, with only the browser injected.

  The listener is not faked, because it is the part that can be wrong. What is
  injected is the one thing a test cannot have — somebody looking at a screen —
  and the stand-in for that is a plain HTTP request to the callback, which is
  exactly what a browser would send.
  """

  use ExUnit.Case, async: true

  alias Lemieux.CLI.OAuth

  # Ask the kernel for a free port instead of folding scheduler-local unique
  # integers into a small range. Concurrent test processes can differ by that
  # range and select the same port, making an OAuth success case test the
  # already-in-use branch by accident.
  defp port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp callback(port), do: "http://127.0.0.1:#{port}/callback"

  # `OAuth.redirect/3` with the link it prints on stderr captured. Printing it
  # is right (the last test says why), but four tests printing it put four
  # authorization prompts in the middle of a passing run.
  defp redirect(url, redirect_uri, opts) do
    {result, _printed} =
      ExUnit.CaptureIO.with_io(:stderr, fn -> OAuth.redirect(url, redirect_uri, opts) end)

    result
  end

  describe "waiting for the redirect" do
    test "returns the parameters the browser was sent to", %{test: _test} do
      port = port()

      open = fn _url ->
        # The browser, arriving at the callback the authorization server
        # redirected it to.
        Task.start(fn ->
          Req.get(callback(port) <> "?code=the-code&state=abc&iss=https%3A%2F%2Fissuer.example",
            retry: false
          )
        end)

        :ok
      end

      assert {:ok, params} =
               redirect("https://issuer.example/authorize", callback(port), open: open)

      assert params["code"] == "the-code"
      assert params["state"] == "abc"
      assert params["iss"] == "https://issuer.example"
    end

    test "answers the browser with a page rather than leaving it hanging" do
      port = port()
      test = self()

      open = fn _url ->
        Task.start(fn -> send(test, {:answered, Req.get(callback(port), retry: false)}) end)

        :ok
      end

      assert {:ok, _params} =
               redirect("https://issuer.example/authorize", callback(port), open: open)

      assert_receive {:answered, {:ok, response}}, 5_000
      assert response.status == 200
      assert response.body =~ "lemieux"
    end

    test "hands the authorization URL to the browser it was told to open" do
      port = port()
      test = self()

      open = fn url ->
        send(test, {:opened, url})
        Task.start(fn -> Req.get(callback(port) <> "?code=c&state=s", retry: false) end)

        :ok
      end

      assert {:ok, _params} =
               redirect("https://issuer.example/authorize?x=1", callback(port), open: open)

      assert_received {:opened, "https://issuer.example/authorize?x=1"}
    end

    test "gives up rather than waiting forever when nobody arrives" do
      port = port()

      assert {:error, reason} =
               redirect("https://issuer.example/authorize", callback(port),
                 open: fn _url -> :ok end,
                 timeout: 60
               )

      assert reason =~ "no redirect"
    end

    # Bound to 127.0.0.1 specifically, which is what the listener binds: a
    # wildcard bind does not collide with it, because SO_REUSEADDR lets a
    # specific address take a port a wildcard socket already holds.
    @tag timeout: 10_000
    test "a port already in use is an error naming the port and the flag to change it" do
      port = port()

      {:ok, socket} =
        :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      on_exit(fn -> :gen_tcp.close(socket) end)

      assert {:error, reason} =
               redirect("https://issuer.example/authorize", callback(port),
                 open: fn _url -> :ok end
               )

      assert reason =~ to_string(port)
      assert reason =~ "--oauth-callback-port"
    end

    test "a callback URI that is not loopback is refused before anything is opened" do
      assert {:error, reason} =
               redirect("https://issuer.example/authorize", "https://example.com/callback",
                 open: fn _url -> flunk("opened a browser for a non-loopback callback") end
               )

      assert reason =~ "loopback"
    end
  end

  describe "the browser that gets opened" do
    test "is the platform's opener, and the URL is printed either way" do
      # Printed as well as opened, because on a machine with no browser — a
      # devbox reached over ssh — the printed URL is the whole flow.
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:error, _reason} =
                   OAuth.redirect("https://issuer.example/authorize", callback(port()),
                     open: fn _url -> :ok end,
                     timeout: 60
                   )
        end)

      assert output =~ "https://issuer.example/authorize"
    end
  end
end

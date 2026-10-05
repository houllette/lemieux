defmodule LemieuxComputerUse.FetchTest do
  use ExUnit.Case, async: true
  alias LemieuxComputerUse.{Fetch, Fixture}
  alias Lemieux.Tools.WebFetch

  defmodule Driver do
    def open(url, opts) do
      send(opts[:owner], {:render_open, self(), url})
      {:ok, {url, opts}}
    end

    def document({url, opts}, _limits) do
      if opts[:stall] do
        receive do
          :never -> {:error, "unreachable"}
        end
      else
        {:ok,
         %{
           "url" => opts[:final_url] || url,
           "html" => "<main>Rendered text<a href='/help.html'>Next</a></main>",
           "ready" => true,
           "truncated" => false
         }}
      end
    end

    def close({_url, opts}), do: send(opts[:owner], :render_closed)
  end

  setup do
    {:ok, server, start} = Fixture.start()
    on_exit(fn -> Fixture.stop(server) end)
    url = String.replace(start, "index.html", "rendered.html")

    opts = [
      allowed_hosts: ["127.0.0.1"],
      unsafe_allow_loopback_for_tests: true,
      owner: self(),
      render_driver: Driver
    ]

    %{url: url, opts: opts, context: %{tool_output_bytes: 100_000, hooks: []}}
  end

  test "only a successful shell escalates and records both stages", ctx do
    assert {:ok, result} = run(ctx)
    assert result.structured_content["source"] == "browser"
    assert result.structured_content["http_fetch"]["extraction"]["needs_render"]
    assert result.structured_content["browser_network_bytes"] == nil
    assert result.structured_content["bytes"] > 0
    assert result.structured_content["text"] =~ "Rendered text"
    assert_receive {:render_open, _, _}
    assert_receive :render_closed
  end

  test "HTTP errors and ordinary short pages never start a renderer", ctx do
    assert {:error, _} =
             run(%{ctx | url: String.replace(ctx.url, "rendered.html", "missing.html")})

    assert {:ok, result} =
             run(%{ctx | url: String.replace(ctx.url, "rendered.html", "help.html")})

    assert result.structured_content["source"] == "http"
    refute_receive {:render_open, _, _}
  end

  test "host disablement and a nested denial retain clearly labelled static output", ctx do
    assert {:ok, result} = run(%{ctx | opts: ctx.opts ++ [browser_fetch: false]})
    assert result.structured_content["source"] == "http"
    refute_receive {:render_open, _, _}

    hooks = [
      before_tool_call: fn call, _ ->
        assert call.name == "web_fetch_render"
        {:deny, "No browser"}
      end
    ]

    assert {:ok, result} = run(%{ctx | context: %{ctx.context | hooks: hooks}})
    assert result.structured_content["rendering"]["outcome"] == "denied"
    assert result.model_text =~ "returning the limited static extraction"
    refute_receive {:render_open, _, _}
  end

  test "disallowed redirect observations close the renderer without exposing their content",
       ctx do
    assert {:ok, result} = run(%{ctx | opts: ctx.opts ++ [final_url: "http://10.0.0.1/"]})
    assert result.structured_content["source"] == "http"
    assert result.structured_content["rendering"]["outcome"] == "error"
    refute result.model_text =~ "Rendered text"
    assert_receive :render_closed
  end

  test "the rendering deadline kills a stalled worker and retains the HTTP result", ctx do
    assert {:ok, result} = run(%{ctx | opts: ctx.opts ++ [stall: true, render_timeout_ms: 150]})
    assert_receive {:render_open, worker, _}
    refute Process.alive?(worker)
    assert result.structured_content["source"] == "http"
    assert result.structured_content["rendering"]["outcome"] == "error"
  end

  test "a byte-capped shell cannot bypass its limit by rendering", ctx do
    http = %{WebFetch.new(unsafe_allow_loopback_for_tests: true) | max_body_bytes: 230}
    assert {:ok, result} = Fetch.run(Fetch.new(http, ctx.opts), %{"url" => ctx.url}, ctx.context)
    assert result.structured_content["body_truncated"]
    assert result.structured_content["extraction"]["needs_render"]
    assert result.structured_content["source"] == "http"
    refute_receive {:render_open, _, _}
  end

  test "a rewritten rendering URL does not start the driver", ctx do
    hooks = [before_tool_call: fn _, _ -> {:rewrite, %{"url" => "https://example.com/"}} end]
    assert {:ok, result} = run(%{ctx | context: %{ctx.context | hooks: hooks}})
    assert result.structured_content["rendering"]["outcome"] == "error"
    refute_receive {:render_open, _, _}
  end

  test "assembly preserves the configured HTTP limits", ctx do
    http = WebFetch.new(max_body_bytes: 32_768, max_text_chars: 1200)
    harness = Lemieux.Harness.new(tools: [http])
    assert {:ok, harness} = Lemieux.Harness.assemble(harness, [{LemieuxComputerUse, ctx.opts}])
    assert [%Fetch{http: ^http}, %LemieuxComputerUse.Tool{}] = harness.tools
  end

  defp run(ctx) do
    tool = Fetch.new(WebFetch.new(unsafe_allow_loopback_for_tests: true), ctx.opts)
    Fetch.run(tool, %{"url" => ctx.url}, ctx.context)
  end
end

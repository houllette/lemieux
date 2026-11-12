defmodule Lemieux.CLI.CodexModelsWatcherTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.CodexModels.Watcher
  alias Lemieux.CLI.{Config, Options}
  alias Lemieux.Clock.Manual
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    runtime = :"codex_models_#{System.unique_integer([:positive])}"
    clock = start_supervised!({Manual, now: -1_000_000})
    start_supervised!({Lemieux.Supervisor, name: runtime})
    path = Path.join(dir, "auth.json")
    save(path, "account-a")
    parent = self()

    get = fn _url, request ->
      account = request[:headers] |> Map.new() |> Map.fetch!("chatgpt-account-id")
      send(parent, {:http, self(), account})

      receive do
        {:response, result} -> result
      after
        60_000 -> {:error, :fixture_timeout}
      end
    end

    options = %Options{model: "openai_codex:chosen", config: %Config{personal: true}}
    opts = [supervisor: runtime, clock: clock, codex_models: [source: path, get: get]]
    %{runtime: runtime, clock: clock, path: path, options: options, opts: opts}
  end

  defp save(path, account, seconds \\ 3600) do
    token =
      "header." <>
        Base.url_encode64(JSON.encode!(%{"exp" => System.system_time(:second) + seconds}),
          padding: false
        ) <> ".signature"

    File.write!(
      path,
      JSON.encode!(%{"tokens" => %{"access_token" => token, "account_id" => account}})
    )
  end

  defp reply(worker, slug) do
    send(
      worker,
      {:response,
       {:ok, %{status: 200, body: %{"models" => [%{"visibility" => "list", "slug" => slug}]}}}}
    )
  end

  test "background discovery caches, refreshes on expiry, and backs off after failure", ctx do
    {:ok, watcher} = Watcher.start(self(), ctx.options, ctx.opts)
    assert_receive {:http, worker, "account-a"}
    assert :ok = Watcher.poll(watcher)
    refute_receive {:http, _, _}, 20
    reply(worker, "model-a")
    assert_receive {:model_catalog, "openai_codex", ["openai_codex:model-a"], nil}
    assert :ok = Watcher.poll(watcher)
    refute_receive {:http, _, _}, 20

    Manual.advance(ctx.clock, 300_000, settle: watcher)
    assert_receive {:http, refresh, "account-a"}
    send(refresh, {:response, {:error, :offline}})
    assert_receive {:model_catalog, "openai_codex", ["openai_codex:model-a"], notice}
    assert notice =~ "stale"
    assert :ok = Watcher.poll(watcher)
    refute_receive {:http, _, _}, 20
    Manual.advance(ctx.clock, 60_000, settle: watcher)
    assert_receive {:http, retry, "account-a"}
    reply(retry, "model-b")
    assert_receive {:model_catalog, "openai_codex", ["openai_codex:model-b"], nil}
    assert :ok = GenServer.stop(watcher)
    assert Manual.pending(ctx.clock) == []
  end

  test "account changes discard the cache and cancel an old in-flight request", ctx do
    {:ok, watcher} = Watcher.start(self(), ctx.options, ctx.opts)
    assert_receive {:model_catalog, "openai_codex", [], nil}
    assert_receive {:http, first, "account-a"}
    reply(first, "only-a")
    assert_receive {:model_catalog, "openai_codex", ["openai_codex:only-a"], nil}
    Manual.advance(ctx.clock, 300_000, settle: watcher)
    assert_receive {:http, old, "account-a"}
    ref = Process.monitor(old)
    save(ctx.path, "account-b")
    assert :ok = Watcher.poll(watcher)
    assert_receive {:DOWN, ^ref, :process, ^old, _}
    assert_receive {:model_catalog, "openai_codex", [], nil}
    assert_receive {:http, current, "account-b"}
    reply(current, "only-b")
    assert_receive {:model_catalog, "openai_codex", ["openai_codex:only-b"], nil}
    save(ctx.path, "account-b", -60)
    assert :ok = Watcher.poll(watcher)
    assert_receive {:model_catalog, "openai_codex", [], notice} when is_binary(notice)
    refute_receive {:http, _, _}, 20
    assert :ok = GenServer.stop(watcher)
  end

  test "a changed credential while HTTP completes cannot publish the old account result", ctx do
    {:ok, watcher} = Watcher.start(self(), ctx.options, ctx.opts)
    assert_receive {:http, worker, "account-a"}
    save(ctx.path, "account-b")
    reply(worker, "only-a")
    assert_receive {:http, current, "account-b"}
    reply(current, "only-b")
    assert_receive {:model_catalog, "openai_codex", ["openai_codex:only-b"], nil}
    refute_receive {:model_catalog, "openai_codex", ["openai_codex:only-a"], _}, 20
    assert :ok = GenServer.stop(watcher)
  end

  test "a hung fetch is bounded and screen exit stops its worker", ctx do
    app =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :stop -> :ok
           end
         end}
      )

    {:ok, watcher} = Watcher.start(app, ctx.options, ctx.opts)
    assert_receive {:http, worker, "account-a"}
    ref = Process.monitor(worker)
    Manual.advance(ctx.clock, 6_000, settle: watcher)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert :ok = Watcher.poll(watcher)
    refute_receive {:http, _, _}, 20
    Manual.advance(ctx.clock, 60_000, settle: watcher)
    assert :ok = Watcher.poll(watcher)
    assert_receive {:http, next, "account-a"}
    next_ref = Process.monitor(next)
    watcher_ref = Process.monitor(watcher)
    send(app, :stop)
    assert_receive {:DOWN, ^watcher_ref, :process, ^watcher, :normal}
    assert_receive {:DOWN, ^next_ref, :process, ^next, _}
    assert Manual.pending(ctx.clock) == []
  end

  test "a timeout after account change cannot republish the previous account's cached models",
       ctx do
    {:ok, watcher} = Watcher.start(self(), ctx.options, ctx.opts)
    assert_receive {:model_catalog, "openai_codex", [], nil}
    assert_receive {:http, first, "account-a"}
    reply(first, "only-a")
    assert_receive {:model_catalog, "openai_codex", ["openai_codex:only-a"], nil}
    Manual.advance(ctx.clock, 300_000, settle: watcher)
    assert_receive {:http, _old, "account-a"}
    save(ctx.path, "account-b")
    Manual.advance(ctx.clock, 6_000, settle: watcher)
    assert_receive {:model_catalog, "openai_codex", [], nil}
    assert_receive {:http, current, "account-b"}
    reply(current, "only-b")
    assert_receive {:model_catalog, "openai_codex", ["openai_codex:only-b"], nil}
    refute_receive {:model_catalog, "openai_codex", ["openai_codex:only-a"], _}, 20
    assert :ok = GenServer.stop(watcher)
  end

  test "custom host providers never start native discovery", ctx do
    assert :ignore =
             Watcher.start(
               self(),
               ctx.options,
               Keyword.put(ctx.opts, :provider, {TestProvider, nil})
             )

    refute_receive {:http, _, _}, 20
  end
end

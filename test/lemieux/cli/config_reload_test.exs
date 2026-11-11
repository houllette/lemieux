defmodule Lemieux.CLI.ConfigReloadTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.{Config, ConfigReload, Options}
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    runtime = :"config_reload_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    path = Path.join(dir, "config.json")
    settings = %{"version" => 1, "systemone_compaction" => %{"mode" => "off"}}
    save(path, settings)
    {:ok, config} = Config.load(path)
    parent = self()

    provider =
      Scripted.new([
        fn _ ->
          send(parent, {:provider_waiting, self()})

          receive do
            :finish -> [{:done, :stop}]
          after
            60_000 -> [{:done, :stop}]
          end
        end,
        Scripted.complete("done")
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        store: JSONL.new(Path.join(dir, "sessions")),
        model: "test:model",
        subscriber: self()
      )

    options = %Options{config: config}
    {:ok, watcher} = ConfigReload.start(session, self(), options)
    %{session: session, watcher: watcher, path: path, settings: settings}
  end

  defp save(path, settings) do
    temporary = path <> ".save"
    File.write!(temporary, JSON.encode!(settings))
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, path)
  end

  test "atomic saves apply live fields, warn about restart fields, and clear reverts", ctx do
    {:ok, _} = Session.put_document(ctx.session, "systemone_compaction", 0, %{"spent_usd" => 12})
    entries = Session.snapshot(ctx.session).entries

    settings =
      Map.merge(ctx.settings, %{
        "sandbox" => false,
        "systemone_compaction" => %{"mode" => "off", "max_evaluations" => 7}
      })

    save(ctx.path, settings)
    assert :ok = ConfigReload.poll(ctx.watcher)
    assert_receive {:config_reload_notice, _, :warning, texts}
    assert Enum.any?(texts, &String.contains?(&1, "Config reloaded"))
    assert Enum.any?(texts, &String.contains?(&1, "Restart lmx to apply: sandbox"))
    assert Session.snapshot(ctx.session).entries == entries

    assert {:ok, %{value: %{"spent_usd" => 12}}} =
             Session.document(ctx.session, "systemone_compaction")

    save(ctx.path, Map.delete(settings, "sandbox"))
    assert :ok = ConfigReload.poll(ctx.watcher)
    assert_receive {:config_reload_notice, _, :info, []}
  end

  test "busy turns retain hooks until idle and malformed or new-schema saves retain working state",
       ctx do
    original = fn request, _context -> {:ok, request} end
    assert :ok = Session.set_request_hooks(ctx.session, [original])
    assert :ok = Session.prompt(ctx.session, "hold")
    assert_receive {:provider_waiting, provider}
    save(ctx.path, put_in(ctx.settings, ["systemone_compaction", "max_evaluations"], 9))
    assert :ok = ConfigReload.poll(ctx.watcher)
    assert_receive {:config_reload_notice, _, :info, [notice]}
    assert notice =~ "active turn finishes"
    assert Session.request_hooks(ctx.session) == [original]
    send(provider, :finish)
    assert_receive {:lemieux, _, {:finished, _}}
    assert :ok = ConfigReload.poll(ctx.watcher)
    assert_receive {:config_reload_notice, _, :info, [notice]}
    assert notice =~ "Config reloaded"
    File.write!(ctx.path, "{")
    assert :ok = ConfigReload.poll(ctx.watcher)
    assert_receive {:config_reload_notice, _, :warning, [notice]}
    assert notice =~ "last working settings"
    save(ctx.path, Map.put(ctx.settings, "version", 2))
    assert :ok = ConfigReload.poll(ctx.watcher)
    refute_receive {:config_reload_notice, _, _, _}
    assert Session.info(ctx.session).status == :idle
  end

  test "hermetic sessions do not start a watcher", ctx do
    assert ConfigReload.start(ctx.session, self(), %Options{}) == :ignore
  end
end

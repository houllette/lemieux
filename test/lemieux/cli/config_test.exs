defmodule Lemieux.CLI.ConfigTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.TUI
  alias Lemieux.TUI.Theme

  @moduletag :tmp_dir

  test "first startup creates a private basic config and preserves later edits", %{tmp_dir: dir} do
    path = Path.join([dir, ".lmx", "config.json"])
    assert {:ok, config} = Config.load_default(path, Options.default_model())
    assert Config.get(config, "model") == nil
    assert Config.get(config, "providers") == %{}
    assert {:ok, %{model: model}} = Options.parse(["--config", path])
    assert model == Options.default_model()
    assert Config.get(config, "ixway") == %{"enabled" => false}

    assert {:ok, route} =
             Config.inference(config, [ixway: "http://localhost:4003"], Options.default_model())

    assert route[:model] == "ixway:@default"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700

    File.write!(path, ~s({"model":"ixway:my-choice"}))
    assert {:ok, config} = Config.load_default(path, Options.default_model())
    assert Config.get(config, "model") == "ixway:my-choice"
    assert File.read!(path) == ~s({"model":"ixway:my-choice"})
  end

  test "concurrent first startups share one complete config", %{tmp_dir: dir} do
    path = Path.join([dir, ".lmx", "config.json"])

    results =
      1..8
      |> Task.async_stream(fn _ -> Config.load_default(path, Options.default_model()) end)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %Config{}}}, &1))
    assert {:ok, settings} = path |> File.read!() |> JSON.decode()
    assert settings["version"] == 1
    assert File.ls!(Path.dirname(path)) == ["config.json"]
  end

  # Documented before it was accepted: the guide said `"mouse": false` turned
  # capture off and the schema rejected the whole file as an unknown field,
  # which is worse than the setting not existing.
  test "the mouse setting is a known boolean, and the flag still beats it", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")

    File.write!(path, ~s({"version":1,"mouse":false}))
    assert {:ok, %{host: %{mouse: false}}} = Options.parse(["--config", path])
    assert {:ok, %{host: %{mouse: true}}} = Options.parse(["--config", path, "--mouse"])
  end

  test "auto-compaction is on by default and a boolean config can disable it", %{tmp_dir: dir} do
    default_path = write_config(dir, %{})
    assert {:ok, default} = Options.parse(["--config", default_path])

    assert {:ok, prepared} =
             Runtime.prepare(default, provider: Scripted.new([]), store: JSONL.new(dir))

    assert prepared.harness.compact_at == :default
    assert prepared.harness.auto_compaction == true

    disabled_path = write_config(dir, %{"auto_compaction" => false})
    assert {:ok, disabled} = Options.parse(["--config", disabled_path])

    assert {:ok, prepared} =
             Runtime.prepare(disabled, provider: Scripted.new([]), store: JSONL.new(dir))

    assert prepared.harness.compact_at == nil
    assert prepared.harness.auto_compaction == false
    assert TUI.new(harness: prepared.harness).status.compact_at == nil

    File.write!(disabled_path, ~s({"auto_compaction":"false"}))
    assert {:error, reason} = Config.load(disabled_path)
    assert reason =~ "auto_compaction"
  end

  test "provider models are scoped and validated", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")
    File.write!(path, ~s({"providers":{"openai":{"model":"openai:gpt-6-sol"}}}))

    assert {:ok, config} = Config.load(path)
    assert Config.preferred_models(config) == %{"openai" => "openai:gpt-6-sol"}

    File.write!(path, ~s({"providers":{"openai":{"model":"anthropic:claude-sonnet-5"}}}))
    assert {:error, reason} = Config.load(path)
    assert reason =~ "providers.openai"
  end

  test "provider sections supply direct startup defaults, credentials and TUI favorites", %{
    tmp_dir: dir
  } do
    path =
      write_config(dir, %{
        "providers" => %{
          "openai" => %{
            "api_key" => "private-key",
            "model" => "openai:gpt-6-sol",
            "effort" => "high"
          }
        }
      })

    assert {:ok, options} = Options.parse(["--config", path])
    assert options.model == "openai:gpt-6-sol"
    assert Config.api_keys(options.config) == %{"openai" => "private-key"}
    assert Config.preferred_models(options.config) == %{"openai" => "openai:gpt-6-sol"}
    assert Config.preferred_efforts(options.config) == %{"openai" => "high"}
    assert Config.effort(options.config, options.model) == "high"
    refute inspect(options) =~ "private-key"

    assert {:ok, prepared} =
             Runtime.prepare(options, provider: Scripted.new([]), store: JSONL.new(dir))

    assert prepared.harness.reasoning_effort == "high"
    assert prepared.options[:reasoning_effort] == "high"
  end

  test "the selected model's provider determines its configured effort", %{tmp_dir: dir} do
    path =
      write_config(dir, %{
        "model" => "openai:gpt-6-sol",
        "providers" => %{
          "openai" => %{"model" => "openai:gpt-6-luna", "effort" => "high"},
          "anthropic" => %{"model" => "anthropic:claude-sonnet-5", "effort" => "low"}
        },
        "ixway" => %{
          "enabled" => true,
          "endpoint" => "http://localhost:4003",
          "model" => "ixway:team/coding",
          "effort" => "medium"
        }
      })

    assert {:ok, ixway} = Options.parse(["--config", path])
    assert ixway.model == "ixway:team/coding"
    assert Config.effort(ixway.config, ixway.model) == "medium"

    assert Config.preferred_efforts(ixway.config) == %{
             "openai" => "high",
             "anthropic" => "low",
             "ixway" => "medium"
           }

    assert {:ok, prepared} =
             Runtime.prepare(ixway, provider: Scripted.new([]), store: JSONL.new(dir))

    assert prepared.options[:reasoning_effort] == "medium"

    assert {:ok, direct} = Options.parse(["--config", path, "--router", "direct"])
    assert direct.model == "openai:gpt-6-sol"
    assert Config.effort(direct.config, direct.model) == "high"

    assert {:ok, override} =
             Options.parse([
               "--config",
               path,
               "--router",
               "direct",
               "--model",
               "anthropic:claude-sonnet-5"
             ])

    assert Config.effort(override.config, override.model) == "low"
  end

  test "legacy key and favorite maps are rejected instead of silently ignored", %{tmp_dir: dir} do
    for legacy <- ["api_keys", "preferred_models"] do
      path = write_config(dir, %{legacy => %{}})
      assert {:error, reason} = Config.load(path)
      assert reason =~ "Unknown field"
    end
  end

  test "provider sections reject unknown fields, mismatched models and invalid efforts", %{
    tmp_dir: dir
  } do
    for settings <- [
          %{"providers" => %{"openai" => %{"modle" => "openai:gpt-6-sol"}}},
          %{"providers" => %{"openai" => %{"model" => "anthropic:claude-sonnet-5"}}},
          %{"providers" => %{"openai" => %{"effort" => ""}}},
          %{"providers" => %{"openai" => %{"api_key" => "secret\nvalue"}}}
        ] do
      path = write_config(dir, settings)
      assert {:error, reason} = Config.load(path)
      assert reason =~ "providers.openai"
      refute reason =~ "secret"
    end
  end

  test "price bands and summary settings reach the shipped host harness", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")

    bands = [
      %{"up_to" => 200_000, "input_per_million" => 2.0, "output_per_million" => 12.0},
      %{"up_to" => nil, "input_per_million" => 4.0, "output_per_million" => 18.0}
    ]

    settings = %{
      "version" => 1,
      "compaction_price_tiers" => %{"google:gemini-3.1-pro-preview" => bands},
      "keep_recent_tokens" => 20_000,
      "summary_model" => "google:gemini-3-flash-preview"
    }

    File.write!(path, JSON.encode!(settings))
    assert {:ok, options} = Options.parse(["--config", path])

    assert {:ok, prepared} =
             Runtime.prepare(options, provider: Scripted.new([]), store: JSONL.new(dir))

    assert prepared.harness.keep_recent_tokens == 20_000
    assert prepared.harness.summary_model == "google:gemini-3-flash-preview"

    assert prepared.harness.compaction_price_tiers["google:gemini-3.1-pro-preview"] == [
             %{up_to: 200_000, input_per_million: 2.0, output_per_million: 12.0},
             %{up_to: nil, input_per_million: 4.0, output_per_million: 18.0}
           ]

    File.write!(
      path,
      JSON.encode!(
        put_in(
          settings,
          ["compaction_price_tiers", "google:gemini-3.1-pro-preview"],
          Enum.reverse(bands)
        )
      )
    )

    assert {:error, reason} = Options.parse(["--config", path])
    assert reason =~ "compaction_price_tiers"

    broken =
      put_in(settings, ["compaction_price_tiers", "google:gemini-3.1-pro-preview"], [
        Map.put(hd(bands), "cached_input_per_million", nil),
        List.last(bands)
      ])

    File.write!(path, JSON.encode!(broken))
    assert {:error, reason} = Options.parse(["--config", path])
    assert reason =~ "compaction_price_tiers"
  end

  test "Jev route settings are data with bounded cost controls", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")

    settings = %{
      "version" => 1,
      "jev_compaction" => %{
        "mode" => "apply",
        "route" => "ixway",
        "model" => "jev-local-1",
        "endpoint" => "http://localhost:4003",
        "max_cost_usd" => 0.05,
        "reservation_per_call_usd" => 0.01,
        "input_per_million" => 0.04,
        "output_per_million" => 0.0
      }
    }

    File.write!(path, JSON.encode!(settings))
    assert {:ok, options} = Options.parse(["--config", path])
    assert Config.get(options.config, "jev_compaction")["route"] == "ixway"

    File.write!(path, JSON.encode!(put_in(settings, ["jev_compaction", "route"], "chat")))
    assert {:error, reason} = Options.parse(["--config", path])
    assert reason =~ "jev_compaction"

    File.write!(
      path,
      JSON.encode!(
        update_in(settings, ["jev_compaction"], &Map.delete(&1, "reservation_per_call_usd"))
      )
    )

    assert {:error, reason} = Options.parse(["--config", path])
    assert reason =~ "jev_compaction"
  end

  test "a Jev key in config stays private and requires private file permissions", %{tmp_dir: dir} do
    path =
      write_config(dir, %{"version" => 1, "jev_compaction" => %{"api_key" => "private-jev-key"}})

    assert {:ok, config} = Config.load(path)
    assert Config.get(config, "jev_compaction")["api_key"] == "private-jev-key"
    refute inspect(config) =~ "private-jev-key"

    File.chmod!(path, 0o644)
    assert {:error, reason} = Config.load(path)
    assert reason =~ "chmod 600"
    refute reason =~ "private-jev-key"
  end

  test "search credentials are scoped separately from model providers and require a private file",
       %{tmp_dir: dir} do
    path =
      write_config(dir, %{
        "web_search_providers" => %{
          "brave" => %{"api_key" => "private-brave-key"},
          "another_search" => %{"api_key" => "private-other-key"}
        }
      })

    assert {:ok, config} = Config.load(path)
    assert Config.api_keys(config) == %{}
    assert Config.web_search_api_key(config, "brave") == "private-brave-key"
    assert Config.web_search_api_key(config, "another_search") == "private-other-key"
    assert Config.web_search_api_key(config, "missing") == nil
    assert Config.web_search_api_key(nil, "brave") == nil
    refute inspect(config) =~ "private-brave-key"
    refute inspect(config) =~ "private-other-key"

    File.chmod!(path, 0o644)
    assert {:error, reason} = Config.load(path)
    assert reason =~ "chmod 600"
    refute reason =~ "private-brave-key"
    refute reason =~ "private-other-key"
  end

  test "search provider sections reject malformed settings without disclosing credentials", %{
    tmp_dir: dir
  } do
    for providers <- [
          "private-invalid-key",
          %{"private-invalid-key!" => %{"api_key" => "private-invalid-key"}},
          %{"brave" => "private-invalid-key"},
          %{"brave" => %{"token" => "private-invalid-key"}},
          %{"brave" => %{"api_key" => ""}},
          %{"brave" => %{"api_key" => "   "}},
          %{"brave" => %{"api_key" => "private-invalid-key\n"}},
          %{"brave" => %{"api_key" => "private-invalid-key\r"}},
          %{"brave" => %{"api_key" => 123}}
        ] do
      path = write_config(dir, %{"web_search_providers" => providers})
      assert {:error, reason} = Config.load(path)
      assert reason =~ "web_search_providers"
      refute reason =~ "private-invalid-key"
    end
  end

  test "empty search-provider sections can omit credentials", %{tmp_dir: dir} do
    path = write_config(dir, %{"web_search_providers" => %{"brave" => %{}}})
    File.chmod!(path, 0o644)
    assert {:ok, config} = Config.load(path)
    assert Config.web_search_api_key(config, "brave") == nil
  end

  test "disabled_extensions accepts unique shipped names only", %{tmp_dir: dir} do
    path =
      write_config(dir, %{"version" => 1, "disabled_extensions" => ["interactive", "delegation"]})

    assert {:ok, config} = Config.load(path)
    assert Config.get(config, "disabled_extensions") == ["interactive", "delegation"]

    for names <- [["interactive", "interactive"], ["unknown"], ["../workspace"]] do
      File.write!(path, JSON.encode!(%{"version" => 1, "disabled_extensions" => names}))
      assert {:error, reason} = Config.load(path)
      assert reason =~ "disabled_extensions"
    end
  end

  test "the theme setting names a palette the screen has, and nothing else", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")

    File.write!(path, ~s({"version":1,"theme":"light"}))
    assert {:ok, options} = Options.parse(["--config", path])
    assert Config.get(options.config, "theme") == "light"

    # Through the runtime's base harness, which is where the screen reads it.
    assert {:ok, prepared} =
             Runtime.prepare(options, provider: Scripted.new([]), store: JSONL.new(dir))

    assert prepared.harness.theme == "light"

    File.write!(path, ~s({"version":1,"theme":"sepia"}))
    assert {:error, message} = Options.parse(["--config", path])
    assert message =~ "theme"
  end

  # A palette of one's own is data, and the file is the place for it. It is
  # checked at load with every bad slot named, because the screen would
  # otherwise raise on it after covering standard error; and the `theme` that
  # starts the sitting may then be one of them, which the per-field check
  # alone could not know.
  test "themes registers palettes the screen offers, and theme may name one", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")
    sepia = Theme.dark() |> Theme.to_map() |> Map.put("name", "sepia")

    File.write!(
      path,
      JSON.encode!(%{"version" => 1, "themes" => %{"sepia" => sepia}, "theme" => "sepia"})
    )

    assert {:ok, options} = Options.parse(["--config", path])
    assert Config.get(options.config, "themes") == %{"sepia" => sepia}

    assert {:ok, prepared} =
             Runtime.prepare(options, provider: Scripted.new([]), store: JSONL.new(dir))

    assert prepared.harness.themes == %{"sepia" => sepia}
    assert prepared.harness.theme == "sepia"

    # Without the registration the same name is refused, as it always was.
    File.write!(path, JSON.encode!(%{"version" => 1, "theme" => "sepia"}))
    assert {:error, message} = Options.parse(["--config", path])
    assert message =~ "theme"
    assert message =~ "sepia"
  end

  test "a theme that cannot be read is refused with every bad slot named", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")

    broken =
      Theme.dark()
      |> Theme.to_map()
      |> put_in(["voices", "you"], "chartreuse-ish")
      |> put_in(["blocks", "code_theme"], "not_a_theme")
      |> Map.delete("context")

    File.write!(path, JSON.encode!(%{"version" => 1, "themes" => %{"sepia" => broken}}))
    assert {:error, message} = Options.parse(["--config", path])

    assert message =~ "themes"
    assert message =~ "sepia: voices.you"
    assert message =~ "sepia: blocks.code_theme"
    assert message =~ "sepia: context: missing"

    File.write!(path, ~s({"version":1,"themes":["dark"]}))
    assert {:error, message} = Options.parse(["--config", path])
    assert message =~ "themes"
  end

  # A key map of one's own is data — names to names — and the file is the
  # place for it. It is checked at load with every problem named, as
  # `"themes"` is, because the screen would otherwise raise on it after
  # covering standard error. The map itself is what reaches the harness;
  # `Lemieux.TUI.Keys` reads it again when the screen opens, and nothing
  # configured leaves the field unset, which the screen reads as its own table.
  test "keys reaches the harness through the runtime, and every bad key or action is named",
       %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")
    store = JSONL.new(dir)

    File.write!(path, ~s({"version":1}))
    assert {:ok, options} = Options.parse(["--config", path])
    assert {:ok, prepared} = Runtime.prepare(options, provider: Scripted.new([]), store: store)
    assert prepared.harness.keys == nil

    keys = %{"ctrl-j" => "submit", "Shift-Ctrl-Up" => "page_up", "tab" => "forward"}
    File.write!(path, JSON.encode!(%{"version" => 1, "keys" => keys}))
    assert {:ok, options} = Options.parse(["--config", path])
    assert Config.get(options.config, "keys") == keys

    assert {:ok, prepared} = Runtime.prepare(options, provider: Scripted.new([]), store: store)
    assert prepared.harness.keys == keys

    broken = %{"hyper-q" => "submit", "ctrl-j" => "levitate", "escape" => "dismiss"}
    File.write!(path, JSON.encode!(%{"version" => 1, "keys" => broken}))
    assert {:error, message} = Options.parse(["--config", path])
    assert message =~ "keys"
    assert message =~ ~s("hyper-q": hyper is not a modifier)
    assert message =~ ~s("ctrl-j": "levitate" is not an action)
    assert message =~ ~s("escape": escape is not a key)

    # ctrl-c taken with nothing left to interrupt on is refused too: the
    # invariant is the key map's, and the file learns of it here.
    File.write!(path, JSON.encode!(%{"version" => 1, "keys" => %{"ctrl-c" => "dismiss"}}))
    assert {:error, message} = Options.parse(["--config", path])
    assert message =~ "keys"
    assert message =~ "interrupt is bound to nothing"

    File.write!(path, ~s({"version":1,"keys":["ctrl-j"]}))
    assert {:error, message} = Options.parse(["--config", path])
    assert message =~ "keys"
  end

  # The persistent form of `--extension`: names, resolved under the personal
  # root when the runtime loads them. A path or a module in the list is
  # refused here so the file cannot be edited into pointing at code.
  test "extensions is a list of names, never paths or modules", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")

    File.write!(path, ~s({"version":1,"extensions":["audit","review-2"]}))
    assert {:ok, options} = Options.parse(["--config", path])
    assert options.extensions == [name: "audit", name: "review-2"]

    for entries <- [
          ~s(["../audit"]),
          ~s(["MyApp.Audit"]),
          ~s(["/abs/audit"]),
          ~s([""]),
          ~s("audit"),
          ~s([1])
        ] do
      File.write!(path, ~s({"version":1,"extensions":#{entries}}))
      assert {:error, message} = Options.parse(["--config", path])
      assert message =~ "extensions", "#{entries} was accepted"
    end
  end

  # The status line does not wrap, so a label longer than the row's share of
  # it pushes the measured half of the line off the right-hand edge. Refused
  # at load rather than shrugged at while drawing: a setting silently ignored
  # when it is wrong is a setting nobody can debug.
  test "the processing labels are a list of short strings, and reach the screen",
       %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")

    File.write!(path, ~s({"version":1,"processing":["Forechecking","Deking"]}))
    assert {:ok, options} = Options.parse(["--config", path])

    assert {:ok, prepared} =
             Runtime.prepare(options, provider: Scripted.new([]), store: JSONL.new(dir))

    assert prepared.harness.processing == ["Forechecking", "Deking"]

    File.write!(path, ~s({"version":1,"processing":[]}))
    assert {:error, message} = Options.parse(["--config", path])
    assert message =~ "processing"

    File.write!(path, ~s({"version":1,"processing":["#{String.duplicate("z", 40)}"]}))
    assert {:error, message} = Options.parse(["--config", path])
    assert message =~ "processing"

    File.write!(path, ~s({"version":1,"processing":"Working"}))
    assert {:error, message} = Options.parse(["--config", path])
    assert message =~ "processing"
  end

  # Same shape, for the repository's own MCP configuration: on unless the
  # config or the flag says otherwise, and `false` rather than `nil` so that
  # "said no" stays distinguishable from "said nothing".
  test "the project MCP setting is a known boolean, and the flag still beats it", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")

    File.write!(path, ~s({"version":1,"project_mcp":false}))
    assert {:ok, %{mcp_config: false}} = Options.parse(["--config", path])
    assert {:ok, %{mcp_config: nil}} = Options.parse(["--config", path, "--project-mcp"])

    assert {:ok, %{mcp_config: "/tmp/servers.json"}} =
             Options.parse(["--config", path, "--mcp-config", "/tmp/servers.json"])

    File.write!(path, ~s({"version":1}))
    assert {:ok, %{host: %{mouse: true}}} = Options.parse(["--config", path])

    File.write!(path, ~s({"version":1,"mouse":"yes"}))
    assert {:error, message} = Options.parse(["--config", path])
    assert message =~ "mouse"
  end

  test "a missing default file is optional but an explicit path must exist", %{tmp_dir: dir} do
    path = Path.join(dir, "missing.json")
    assert {:ok, config} = Config.load(path, optional: true)
    assert Config.get(config, "model") == nil
    assert {:error, _} = Options.parse(["--config", path])
  end

  test "loads a private config and keeps credentials out of inspection", %{tmp_dir: dir} do
    path =
      write_config(dir, %{
        "model" => "openai:gpt-5",
        "providers" => %{"openai" => %{"api_key" => "private-key"}}
      })

    assert {:ok, options} = Options.parse(["--config", path])
    assert options.model == "openai:gpt-5"
    refute Keyword.has_key?(options.given, :model)
    refute inspect(options) =~ "private-key"
    assert {_, state} = Runtime.provider(options)
    assert state.api_key_defaults == %{"openai" => "private-key"}
    refute inspect(state) =~ "private-key"
  end

  test "Ixway file settings enable the router and flags can override it", %{tmp_dir: dir} do
    path =
      write_config(dir, %{
        "model" => "openai:gpt-5",
        "ixway" => %{
          "enabled" => true,
          "endpoint" => "http://localhost:4003",
          "api_key" => "gateway-key",
          "model" => "ixway:team/coding"
        }
      })

    assert {:ok, options} = Options.parse(["--config", path])
    assert options.ixway == "http://localhost:4003"
    assert options.model == "ixway:team/coding"
    assert Lemieux.Ixway.connection(Runtime.provider(options)).api_key == "gateway-key"

    assert {:ok, %{ixway: nil, model: "openai:gpt-5"}} =
             Options.parse(["--config", path, "--router", "direct"])

    assert {:ok, %{model: "ixway:another"}} =
             Options.parse(["--config", path, "--model", "ixway:another"])
  end

  test "invalid JSON, typos and insecure secret files fail without echoing contents", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "config.json")

    for content <- [
          ~s({"providers":{"openai":{"api_key":"private-key"}),
          ~s({"modle":"private-key"}),
          ~s({"ixway":{"enabled":"private-key"}})
        ] do
      File.write!(path, content)
      File.chmod!(path, 0o600)
      assert {:error, message} = Options.parse(["--config", path])
      refute message =~ "private-key"
    end

    write_config(dir, %{"providers" => %{"openai" => %{"api_key" => "private-key"}}})
    File.chmod!(path, 0o644)
    assert {:error, message} = Options.parse(["--config", path])
    assert message =~ "600"
    refute message =~ "private-key"
  end

  test "resume preserves the recorded model and system while credentials stay out of transcripts",
       %{tmp_dir: dir} do
    path =
      write_config(dir, %{
        "model" => "openai:gpt-4o-mini",
        "system" => "original system",
        "providers" => %{"openai" => %{"api_key" => "private-file-key"}}
      })

    store = JSONL.new(Path.join(dir, "sessions"))
    supervisor = :"lmx_config_resume_#{System.unique_integer([:positive])}"
    provider = Scripted.new([])
    assert {:ok, options} = Options.parse(["--config", path])

    assert {:ok, session} =
             Runtime.start_session(options,
               store: store,
               supervisor: supervisor,
               provider: provider,
               tools: []
             )

    id = Session.id(session)
    Supervisor.stop(supervisor)

    write_config(dir, %{
      "model" => "anthropic:claude-sonnet-5",
      "system" => "changed system",
      "providers" => %{"anthropic" => %{"api_key" => "changed-file-key"}}
    })

    assert {:ok, options} = Options.parse(["--config", path, "--resume", id])

    assert {:ok, resumed} =
             Runtime.start_session(options,
               store: store,
               supervisor: supervisor,
               provider: provider,
               tools: []
             )

    state = :sys.get_state(resumed)
    assert state.model == "openai:gpt-4o-mini"
    # The recorded prompt, not the changed file's; what lmx composes after it
    # (the environment block) is refreshed on resume.
    assert String.starts_with?(state.system, "original system")
    refute state.system =~ "changed system"
    Supervisor.stop(supervisor)
    files = dir |> Path.join("sessions/**/*.jsonl") |> Path.wildcard()
    assert files != []
    content = Enum.map_join(files, &File.read!/1)
    refute content =~ "private-file-key"
    refute content =~ "changed-file-key"
    refute content =~ "config.json"
  end

  test "an unknown field is named, with a suggestion, and ignored", %{tmp_dir: dir} do
    path = write_config(dir, %{"thme" => "dark", "from_the_future" => true})

    assert {:ok, config} = Config.load(path)
    assert [future, typo] = Config.warnings(config)
    assert typo =~ ~s("thme") and typo =~ ~s("theme")
    assert future =~ ~s("from_the_future")
    assert Config.get(config, "thme") == nil
  end

  test "a default file that cannot be created falls back to defaults with a warning",
       %{tmp_dir: dir} do
    locked = Path.join(dir, "locked")
    File.mkdir_p!(locked)
    File.chmod!(locked, 0o500)
    on_exit(fn -> File.chmod(locked, 0o700) end)

    assert {:ok, config} = Config.load_default(Path.join([locked, ".lmx", "config.json"]), "x:y")
    assert Config.path(config) == nil
    assert [warning] = Config.warnings(config)
    assert warning =~ "built-in defaults"

    # Still somebody's settings, unlike `--config none`: lmx may pick a model
    # from the keys this machine has (`Lemieux.CLI.Models`).
    assert Config.personal?(config)
  end

  test "only --config none, and no configuration at all, are not personal", %{tmp_dir: dir} do
    assert {:ok, none} = Config.from_cli([config: "none"], "x:y")
    refute Config.personal?(none)
    refute Config.personal?(nil)

    assert {:ok, created} = Config.load_default(Path.join([dir, ".lmx", "config.json"]), "x:y")
    assert Config.personal?(created)

    path = write_config(dir, %{"theme" => "dark"})
    assert {:ok, chosen} = Config.from_cli([config: path], "x:y")
    assert Config.personal?(chosen)
  end

  test "a key and a model are saved privately, keeping what the file had", %{tmp_dir: dir} do
    path = write_config(dir, %{"theme" => "dark"})
    File.chmod!(path, 0o644)

    assert :ok = Config.put_provider_key(path, "anthropic", " sk-test ")
    assert :ok = Config.put_model(path, "anthropic:claude-sonnet-5")
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

    assert {:ok, config} = Config.load(path)
    assert Config.api_keys(config) == %{"anthropic" => "sk-test"}
    assert Config.get(config, "model") == "anthropic:claude-sonnet-5"
    assert Config.get(config, "theme") == "dark"

    assert {:error, _} = Config.put_provider_key(path, "Not A Provider", "k")
    assert {:error, _} = Config.put_provider_key(path, "openai", "two\nlines")
    assert {:error, _} = Config.put_model(path, "no-provider")
    assert :ok = Config.put_provider_key(Path.join([dir, "new", "config.json"]), "openai", "k")
  end

  test "an MCP server is saved as the person's own, in .mcp.json's shape", %{tmp_dir: dir} do
    path = write_config(dir, %{"mcp_servers" => %{"old" => %{"command" => "old"}}})

    server = %{"name" => "docs", "transport" => "http", "url" => "https://d/mcp", "source" => "x"}
    assert :ok = Config.put_mcp_server(path, server)

    assert %{"old" => _, "docs" => %{"type" => "http", "url" => "https://d/mcp"} = docs} =
             JSON.decode!(File.read!(path))["mcp_servers"]

    refute Map.has_key?(docs, "source")
    assert {:error, _} = Config.put_mcp_server(path, %{"url" => "https://nameless"})
  end

  test "input modalities are a fixed vocabulary", %{tmp_dir: dir} do
    assert {:ok, config} =
             Config.load(write_config(dir, %{"input_modalities" => ["text", "image"]}))

    assert Config.input_modalities(config) == [:text, :image]
    assert {:error, _} = Config.load(write_config(dir, %{"input_modalities" => ["smell"]}))
  end

  test "skills takes omarchy and disabled, and refuses anything else by name", %{tmp_dir: dir} do
    assert {:ok, config} =
             Config.load(
               write_config(dir, %{
                 "skills" => %{"omarchy" => false, "disabled" => ["diagnose-crash", "kit:review"]}
               })
             )

    assert Config.get(config, "skills")["disabled"] == ["diagnose-crash", "kit:review"]

    assert {:error, unknown} =
             Config.load(write_config(dir, %{"skills" => %{"omarchyy" => false}}))

    assert unknown =~ ~s(Unknown field "omarchyy" in lmx skills section)
    assert unknown =~ ~s(did you mean "omarchy"?)

    for invalid <- [
          %{"omarchy" => "no"},
          %{"disabled" => "diagnose-crash"},
          %{"disabled" => ["Has Spaces"]},
          %{"disabled" => [""]}
        ] do
      assert {:error, reason} = Config.load(write_config(dir, %{"skills" => invalid}))
      assert reason =~ "Invalid lmx skills setting"
    end

    assert {:error, _not_an_object} = Config.load(write_config(dir, %{"skills" => ["x"]}))
  end

  defp write_config(dir, content) do
    path = Path.join(dir, "config.json")
    File.write!(path, JSON.encode!(content))
    File.chmod!(path, 0o600)
    path
  end
end

defmodule Lemieux.CLI.JevCompactionTest do
  # The library's own suite has no Jev extension loaded, which is the case a
  # source checkout of the library meets. The bundled case is covered by the
  # release host's suite (dist/lmx/test/lmx/jev_compaction_test.exs). What
  # can be checked here is the choice of provider, which `provider/2` makes
  # before any extension is involved.
  #
  # Not async: the choice reads JEV_API_KEY and IXWAY_API_KEY, and a declared
  # provider's own variable, which these tests set and clear.
  use ExUnit.Case, async: false

  alias Lemieux.CLI.{Config, JevCompaction}

  @variables ~w(JEV_API_KEY IXWAY_API_KEY SCORER_TEST_KEY)

  setup do
    previous = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "without the extension, an unconfigured or switched-off host adds nothing" do
    assert JevCompaction.spec(%Config{}, nil) == {:ok, nil}
    assert JevCompaction.spec(nil, nil) == {:ok, nil}

    off = %Config{settings: %{"jev_compaction" => %{"mode" => "off", "api_key" => "unused"}}}
    assert JevCompaction.spec(off, nil) == {:ok, nil}
  end

  test "asking for Jev without the extension names where the bundled one lives" do
    config = %Config{settings: %{"jev_compaction" => %{"mode" => "apply"}}}

    assert {:error, message} = JevCompaction.spec(config, nil)
    assert message =~ "the installed lmx bundles"
    assert message =~ "dist/lmx/extensions/jev_compaction"
    refute message =~ "examples/"
  end

  describe "provider/2" do
    @local %{
      "base_url" => "http://127.0.0.1:8080/scorer",
      "model" => "jev-local-1",
      "headers" => %{"X-Scorer-Tenant" => "team-a"}
    }

    test "a declared endpoint is selected by name, keyless, with its own model and headers" do
      config = config(%{"provider" => "local"}, %{"local" => @local})

      assert JevCompaction.provider(config, nil) ==
               {:ok,
                %{
                  name: "local",
                  type: :endpoint,
                  base_url: "http://127.0.0.1:8080/scorer",
                  api_key: nil,
                  api_key_header: nil,
                  headers: %{"X-Scorer-Tenant" => "team-a"},
                  model: "jev-local-1"
                }}

      # The section's model is the person's override of the entry's default.
      pinned = config(%{"provider" => "local", "model" => "jev-local-2"}, %{"local" => @local})
      assert {:ok, %{model: "jev-local-2"}} = JevCompaction.provider(pinned, nil)

      # A provider with neither has no model to ask for, which is said, not guessed.
      bare = config(%{"provider" => "local"}, %{"local" => Map.delete(@local, "model")})
      assert {:unavailable, reason} = JevCompaction.provider(bare, nil)
      assert reason =~ "the local provider has no model"
      assert reason =~ "jev_compaction.model"
    end

    test "a declared provider's key comes from its variable first, then its saved key" do
      entry = Map.put(@local, "api_key_env", "SCORER_TEST_KEY")
      config = config(%{"provider" => "local"}, %{"local" => entry})

      assert {:unavailable, reason} = JevCompaction.provider(config, nil)
      assert reason == "the local provider reads its key from SCORER_TEST_KEY, which is not set"

      saved =
        config(%{"provider" => "local"}, %{"local" => Map.put(entry, "api_key", "saved-key")})

      assert {:ok, %{api_key: "saved-key", api_key_header: nil}} =
               JevCompaction.provider(saved, nil)

      # The header the key travels in is the entry's to name.
      headed =
        config(%{"provider" => "local"}, %{
          "local" =>
            Map.merge(entry, %{"api_key" => "saved-key", "api_key_header" => "X-API-Key"})
        })

      assert {:ok, %{api_key: "saved-key", api_key_header: "X-API-Key"}} =
               JevCompaction.provider(headed, nil)

      System.put_env("SCORER_TEST_KEY", "key-from-the-environment")
      assert {:ok, %{api_key: "key-from-the-environment"}} = JevCompaction.provider(saved, nil)
      assert {:ok, %{api_key: "key-from-the-environment"}} = JevCompaction.provider(config, nil)

      # An empty variable switches the saved key off, as an empty JEV_API_KEY does.
      System.put_env("SCORER_TEST_KEY", "")
      assert {:unavailable, reason} = JevCompaction.provider(saved, nil)
      assert reason =~ "SCORER_TEST_KEY, which is set but empty"
    end

    test "a selected declared provider wins over complete TypeSafe and Ixway credentials" do
      System.put_env("JEV_API_KEY", "hosted-key-that-must-not-be-used")
      System.put_env("IXWAY_API_KEY", "gateway-key-that-must-not-be-used")

      config = %Config{
        settings: %{
          "ixway" => %{"endpoint" => "http://localhost:4003"},
          "jev_compaction" => %{"provider" => "local", "api_key" => "saved-hosted-key"},
          "jev_compaction_providers" => %{"local" => @local}
        }
      }

      assert {:ok, %{name: "local", base_url: "http://127.0.0.1:8080/scorer", api_key: nil}} =
               JevCompaction.provider(config, "http://localhost:4004")
    end

    test "a declared provider that is not selected neither enables the step nor is chosen" do
      declared = config(%{}, %{"local" => @local})

      # No provider named, no built-in route complete: off, and the reason
      # says how each kind of provider would be completed.
      assert {:unavailable, reason} = JevCompaction.provider(declared, nil)
      assert reason =~ "no provider is complete"
      assert reason =~ "JEV_API_KEY"
      assert reason =~ "jev_compaction.provider to select it"

      # A hosted key beside it chooses TypeSafe, never the declared one.
      System.put_env("JEV_API_KEY", "hosted-test-key")

      assert {:ok, %{name: "typesafe", type: :typesafe, api_key: "hosted-test-key", model: nil}} =
               JevCompaction.provider(declared, nil)

      # Selecting TypeSafe by name without its key is TypeSafe's refusal, with
      # nothing said about the declared provider's complete entry.
      System.delete_env("JEV_API_KEY")
      typesafe = config(%{"provider" => "typesafe"}, %{"local" => @local})
      assert {:unavailable, reason} = JevCompaction.provider(typesafe, nil)
      assert reason =~ "the TypeSafe provider has no key"
      refute reason =~ "local"
    end

    test "the built-in choice between TypeSafe and Ixway is the one lmx always made" do
      System.put_env("JEV_API_KEY", "hosted-test-key")
      System.put_env("IXWAY_API_KEY", "gateway-test-key")

      # A pinned Ixway route wins over the hosted key, and takes its endpoint
      # from the section, the route lmx is using, or the ixway section.
      pinned = config(%{"model" => "jev-local-1", "endpoint" => "http://localhost:4003"}, %{})

      assert {:ok,
              %{
                name: "ixway",
                type: :endpoint,
                base_url: "http://localhost:4003",
                api_key: "gateway-test-key",
                model: "jev-local-1"
              }} = JevCompaction.provider(pinned, nil)

      routed = config(%{"model" => "jev-local-1"}, %{})

      assert {:ok, %{name: "ixway", base_url: "http://localhost:4004"}} =
               JevCompaction.provider(routed, "http://localhost:4004")

      saved = %Config{
        settings: %{
          "ixway" => %{"endpoint" => "http://localhost:4005"},
          "jev_compaction" => %{"model" => "jev-local-1"}
        }
      }

      assert {:ok, %{name: "ixway", base_url: "http://localhost:4005"}} =
               JevCompaction.provider(saved, nil)

      # Without the pin, the hosted key; `route: "auto"` and `route:
      # "typesafe"` are the older spellings of the same choices.
      assert {:ok, %{name: "typesafe", base_url: "https://api.typesafe.ai"}} =
               JevCompaction.provider(config(%{"endpoint" => "http://localhost:4003"}, %{}), nil)

      assert {:ok, %{name: "ixway"}} =
               JevCompaction.provider(
                 config(%{"route" => "auto", "model" => "jev-local-1"}, %{}),
                 "http://localhost:4004"
               )

      assert {:ok, %{name: "typesafe", model: "jev-local-1"}} =
               JevCompaction.provider(
                 config(%{"route" => "typesafe", "model" => "jev-local-1"}, %{}),
                 "http://localhost:4004"
               )

      # The older spelling selects Ixway too, and its refusal names what is missing.
      System.delete_env("IXWAY_API_KEY")

      older =
        config(
          %{"route" => "ixway", "model" => "jev-local-1", "endpoint" => "http://localhost:4003"},
          %{}
        )

      assert {:unavailable, reason} = JevCompaction.provider(older, nil)

      assert reason ==
               "the Ixway provider is missing the Ixway key (IXWAY_API_KEY, or ixway.api_key in the config file)"

      assert {:unavailable, reason} =
               JevCompaction.provider(config(%{"provider" => "ixway"}, %{}), nil)

      assert reason =~ "is missing an endpoint ("
      assert reason =~ "), a pinned jev_compaction.model and the Ixway key ("
    end

    test "a selected name nobody declared is unavailable, not sent anywhere" do
      System.put_env("JEV_API_KEY", "hosted-test-key")
      config = config(%{"provider" => "elsewhere"}, %{"local" => @local})
      assert {:unavailable, reason} = JevCompaction.provider(config, nil)
      assert reason =~ "does not declare"
      refute reason =~ "elsewhere"
    end

    defp config(jev, providers),
      do: %Config{
        settings: %{"jev_compaction" => jev, "jev_compaction_providers" => providers}
      }
  end
end

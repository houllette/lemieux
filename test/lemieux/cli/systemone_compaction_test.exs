defmodule Lemieux.CLI.SystemOneCompactionTest do
  # The library's own suite has no System One compaction extension loaded,
  # which is the case a source checkout of the library meets. The bundled case
  # is covered by the release host's suite
  # (dist/lmx/test/lmx/systemone_compaction_test.exs). What can be checked
  # here is the choice of provider, which `provider/2` makes before any
  # extension is involved.
  #
  # Not async: the choice reads JEV_API_KEY and IXWAY_API_KEY, and a declared
  # provider's own variable, which these tests set and clear.
  use ExUnit.Case, async: false

  alias Lemieux.CLI.{Config, SystemOneCompaction}

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
    assert SystemOneCompaction.spec(%Config{}, nil) == {:ok, nil}
    assert SystemOneCompaction.spec(nil, nil) == {:ok, nil}

    off = %Config{settings: %{"systemone_compaction" => %{"mode" => "off"}}}
    assert SystemOneCompaction.spec(off, nil) == {:ok, nil}
  end

  test "asking for the step without the extension names where the bundled one lives" do
    config = %Config{settings: %{"systemone_compaction" => %{"mode" => "apply"}}}

    assert {:error, message} = SystemOneCompaction.spec(config, nil)
    assert message =~ "the installed lmx bundles"
    assert message =~ "dist/lmx/extensions/systemone_compaction"
    refute message =~ "examples/"
  end

  describe "provider/2" do
    @local %{
      "base_url" => "http://127.0.0.1:8080/scorer",
      "model" => "local-scorer-1",
      "headers" => %{"X-Scorer-Tenant" => "team-a"}
    }

    test "a declared endpoint is selected by name, keyless, with its own model and headers" do
      config = config(%{"provider" => "local"}, %{"local" => @local})

      assert SystemOneCompaction.provider(config, nil) ==
               {:ok,
                %{
                  name: "local",
                  type: :endpoint,
                  base_url: "http://127.0.0.1:8080/scorer",
                  api_key: nil,
                  api_key_header: nil,
                  headers: %{"X-Scorer-Tenant" => "team-a"},
                  model: "local-scorer-1"
                }}

      # A provider without a model has nothing to ask for, which is said, not guessed.
      bare = config(%{"provider" => "local"}, %{"local" => Map.delete(@local, "model")})
      assert {:unavailable, reason} = SystemOneCompaction.provider(bare, nil)
      assert reason =~ "the local provider has no model"
      assert reason =~ "systemone_providers entry"
    end

    test "a declared provider's key comes from its variable first, then its saved key" do
      entry = Map.put(@local, "api_key_env", "SCORER_TEST_KEY")
      config = config(%{"provider" => "local"}, %{"local" => entry})

      assert {:unavailable, reason} = SystemOneCompaction.provider(config, nil)
      assert reason == "the local provider reads its key from SCORER_TEST_KEY, which is not set"

      saved =
        config(%{"provider" => "local"}, %{"local" => Map.put(entry, "api_key", "saved-key")})

      assert {:ok, %{api_key: "saved-key", api_key_header: nil}} =
               SystemOneCompaction.provider(saved, nil)

      # The header the key travels in is the entry's to name.
      headed =
        config(%{"provider" => "local"}, %{
          "local" =>
            Map.merge(entry, %{"api_key" => "saved-key", "api_key_header" => "X-API-Key"})
        })

      assert {:ok, %{api_key: "saved-key", api_key_header: "X-API-Key"}} =
               SystemOneCompaction.provider(headed, nil)

      System.put_env("SCORER_TEST_KEY", "key-from-the-environment")

      assert {:ok, %{api_key: "key-from-the-environment"}} =
               SystemOneCompaction.provider(saved, nil)

      # An empty variable switches the saved key off, as an empty JEV_API_KEY does.
      System.put_env("SCORER_TEST_KEY", "")
      assert {:unavailable, reason} = SystemOneCompaction.provider(saved, nil)
      assert reason =~ "SCORER_TEST_KEY, which is set but empty"
    end

    test "a declared provider that is not selected neither enables the step nor is chosen" do
      declared = config(%{}, %{"local" => @local})

      # No provider named, no built-in provider complete: off, and the reason
      # says how each kind would be completed.
      assert {:unavailable, reason} = SystemOneCompaction.provider(declared, nil)
      assert reason =~ "no provider is complete"
      assert reason =~ "JEV_API_KEY"
      assert reason =~ "systemone_compaction.provider to select it"

      # A hosted key beside it chooses TypeSafe, never the declared one.
      System.put_env("JEV_API_KEY", "hosted-test-key")

      assert {:ok, %{name: "typesafe", type: :typesafe, api_key: "hosted-test-key", model: nil}} =
               SystemOneCompaction.provider(declared, nil)

      # Selecting TypeSafe by name without its key is TypeSafe's refusal, with
      # nothing said about the declared provider's complete entry.
      System.delete_env("JEV_API_KEY")
      typesafe = config(%{"provider" => "typesafe"}, %{"local" => @local})
      assert {:unavailable, reason} = SystemOneCompaction.provider(typesafe, nil)
      assert reason =~ "the typesafe provider has no key"
      assert reason =~ "systemone_providers.typesafe.api_key"
      refute reason =~ "local"
    end

    test "a selected declared provider wins over complete TypeSafe and Ixway credentials" do
      System.put_env("JEV_API_KEY", "hosted-key-that-must-not-be-used")
      System.put_env("IXWAY_API_KEY", "gateway-key-that-must-not-be-used")

      config = %Config{
        settings: %{
          "ixway" => %{"endpoint" => "http://localhost:4003"},
          "systemone_compaction" => %{"provider" => "local"},
          "systemone_providers" => %{
            "local" => @local,
            "typesafe" => %{"api_key" => "saved-hosted-key"},
            "ixway" => %{"model" => "gateway-scorer-1"}
          }
        }
      }

      assert {:ok, %{name: "local", base_url: "http://127.0.0.1:8080/scorer", api_key: nil}} =
               SystemOneCompaction.provider(config, "http://localhost:4004")
    end

    test "TypeSafe's entry holds its key and model, and JEV_API_KEY overrides the saved key" do
      typesafe =
        config(%{"provider" => "typesafe"}, %{
          "typesafe" => %{"api_key" => "saved-key", "model" => "jev-latest"}
        })

      assert {:ok,
              %{
                name: "typesafe",
                type: :typesafe,
                base_url: "https://api.typesafe.ai",
                api_key: "saved-key",
                model: "jev-latest"
              }} = SystemOneCompaction.provider(typesafe, nil)

      System.put_env("JEV_API_KEY", "key-from-the-environment")

      assert {:ok, %{api_key: "key-from-the-environment"}} =
               SystemOneCompaction.provider(typesafe, nil)

      System.put_env("JEV_API_KEY", "")
      assert {:unavailable, _reason} = SystemOneCompaction.provider(typesafe, nil)
    end

    test "with no provider named, a pinned Ixway scorer wins over a TypeSafe key" do
      System.put_env("JEV_API_KEY", "hosted-test-key")
      System.put_env("IXWAY_API_KEY", "gateway-test-key")

      # The Ixway endpoint is the entry's, the route lmx uses, or the ixway section's.
      pinned =
        config(%{}, %{
          "ixway" => %{"base_url" => "http://localhost:4003", "model" => "gateway-scorer-1"}
        })

      assert {:ok,
              %{
                name: "ixway",
                type: :endpoint,
                base_url: "http://localhost:4003",
                api_key: "gateway-test-key",
                model: "gateway-scorer-1"
              }} = SystemOneCompaction.provider(pinned, nil)

      routed = config(%{}, %{"ixway" => %{"model" => "gateway-scorer-1"}})

      assert {:ok, %{name: "ixway", base_url: "http://localhost:4004"}} =
               SystemOneCompaction.provider(routed, "http://localhost:4004")

      saved = %Config{
        settings: %{
          "ixway" => %{"endpoint" => "http://localhost:4005"},
          "systemone_providers" => %{"ixway" => %{"model" => "gateway-scorer-1"}}
        }
      }

      assert {:ok, %{name: "ixway", base_url: "http://localhost:4005"}} =
               SystemOneCompaction.provider(saved, nil)

      # Without a model for Ixway, the hosted key.
      unpinned = config(%{}, %{"ixway" => %{"base_url" => "http://localhost:4003"}})

      assert {:ok, %{name: "typesafe", base_url: "https://api.typesafe.ai"}} =
               SystemOneCompaction.provider(unpinned, nil)

      # Ixway selected by name without its key names exactly what is missing.
      System.delete_env("IXWAY_API_KEY")

      named =
        config(%{"provider" => "ixway"}, %{
          "ixway" => %{"base_url" => "http://localhost:4003", "model" => "gateway-scorer-1"}
        })

      assert {:unavailable, reason} = SystemOneCompaction.provider(named, nil)

      assert reason ==
               "the ixway provider is missing the Ixway key (IXWAY_API_KEY, or ixway.api_key in the config file)"

      assert {:unavailable, reason} =
               SystemOneCompaction.provider(config(%{"provider" => "ixway"}, %{}), nil)

      assert reason =~ "is missing an endpoint ("

      assert reason =~
               "), a model (systemone_providers.ixway.model) and the Ixway key ("
    end

    test "a selected name nobody declared is unavailable, not sent anywhere" do
      System.put_env("JEV_API_KEY", "hosted-test-key")
      config = config(%{"provider" => "elsewhere"}, %{"local" => @local})
      assert {:unavailable, reason} = SystemOneCompaction.provider(config, nil)
      assert reason =~ "does not declare"
      refute reason =~ "elsewhere"
    end

    defp config(section, providers),
      do: %Config{
        settings: %{
          "systemone_compaction" => section,
          "systemone_providers" => providers
        }
      }
  end
end

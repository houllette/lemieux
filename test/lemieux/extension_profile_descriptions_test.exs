defmodule Lemieux.ExtensionProfileDescriptionsTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Builder.Workflow
  alias Lemieux.Providers.Scripted
  alias Lemieux.Tool
  alias Lemieux.Tool.Override
  alias Lemieux.Tools.Bash
  alias Lemieux.Tools.Read

  defmodule Lookup do
    @behaviour Lemieux.Tool

    @impl true
    def name, do: "lookup"

    @impl true
    def description, do: "Look a record up by its key."

    @impl true
    def schema,
      do: %{
        "type" => "object",
        "properties" => %{"key" => %{"type" => "string"}},
        "required" => ["key"],
        "additionalProperties" => false
      }

    @impl true
    def run(%{"key" => key}, _context), do: {:ok, "record #{key}"}
  end

  @registry [tool_registry: [Lookup]]
  @descriptions %{
    "read" => "Open one file by path. Reach for this before `bash cat`.",
    "lookup" => "Find the record behind a key. Keys come from the task, never guessed."
  }

  test "profiles without the option validate exactly as before, metered or quota" do
    assert :ok = Profile.validate(profile(), @registry)
    assert :ok = profile() |> Profile.quota(3) |> Profile.validate(@registry)
  end

  test "accepts a description for each listed built-in or registry tool" do
    profile = described(@descriptions)

    assert :ok = Profile.validate(profile, @registry)
    assert :ok = profile |> Profile.quota(3) |> Profile.validate(@registry)
    assert :ok = described(%{"read" => "Only one tool described."}) |> Profile.validate(@registry)
  end

  test "rejects descriptions for tools the profile does not list, the host workflow tool, and malformed shapes" do
    rejected = [
      %{"write" => "listed by lemieux, not by this profile"},
      %{"nope" => "no such tool"},
      %{"extension_workflow" => "a host tool cannot be redescribed from a profile"},
      %{"read" => ""},
      %{"read" => "  \n"},
      %{"read" => 1},
      %{"read" => nil},
      %{"read" => @descriptions["read"], "nope" => "one bad key spoils the map"},
      ["read"],
      "read",
      nil
    ]

    for descriptions <- rejected do
      assert {:error, :invalid_session_profile} =
               Profile.validate(described(descriptions), @registry),
             "expected #{inspect(descriptions)} to be rejected"
    end
  end

  test "session_options wraps described tools in overrides and leaves the others as modules" do
    provider = Scripted.new([])

    assert {:ok, options} =
             Profile.session_options(described(@descriptions), provider, @registry)

    assert [
             %Override{tool: Read},
             Bash,
             %Override{tool: Lookup}
           ] = options[:tools]

    assert Enum.map(options[:tools], &Tool.name/1) == ["read", "bash", "lookup"]

    assert Enum.map(options[:tools], &Tool.description/1) == [
             @descriptions["read"],
             Bash.description(),
             @descriptions["lookup"]
           ]

    assert Enum.map(options[:tools], &Tool.schema/1) ==
             Enum.map([Read, Bash, Lookup], &Tool.schema/1)

    assert [%Workflow{}] = options[:host_tools]
    assert :ok = Tool.validate_all(options[:tools] ++ options[:host_tools])
  end

  test "session_options without the option resolves plain modules" do
    assert {:ok, options} = Profile.session_options(profile(), Scripted.new([]), @registry)
    assert options[:tools] == [Read, Bash, Lookup]
  end

  test "descriptions are part of the profile's recorded digest" do
    {:ok, plain} = Profile.session_options(profile(), Scripted.new([]), @registry)

    {:ok, described} =
      Profile.session_options(described(@descriptions), Scripted.new([]), @registry)

    digest = &get_in(&1, [:harness_context, "extensions", "session_profile", "profile_sha256"])
    assert digest.(plain) != digest.(described)
  end

  defp profile do
    %{
      "execution" => "live",
      "model" => "test:model",
      "tools" => ["read", "bash", "lookup", "extension_workflow"],
      "options" => %{
        "system" => "Summarize local reports.",
        "max_turns" => 4,
        "max_tokens" => 512,
        "temperature" => 0.2,
        "max_cost_usd" => 0.5,
        "reasoning_effort" => "default"
      }
    }
  end

  defp described(descriptions),
    do: put_in(profile(), ["options", "tool_descriptions"], descriptions)
end

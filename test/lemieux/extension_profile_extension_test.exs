defmodule Lemieux.ExtensionProfileExtensionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extension.Profile
  alias Lemieux.Extensions.Delegation
  alias Lemieux.Extensions.Interactive
  alias Lemieux.Harness
  alias Lemieux.Learning.Builder.Workflow
  alias Lemieux.Providers.Scripted
  alias Lemieux.Tool
  alias Lemieux.Tools

  defp profile do
    %{
      "execution" => "live",
      "model" => "test:model",
      "tools" => ["read", "bash", "extension_workflow"],
      "options" => %{
        "system" => "Summarize local reports.",
        "max_turns" => 6,
        "max_tokens" => 2048,
        "max_cost_usd" => 0.5,
        "reasoning_effort" => "default",
        "temperature" => 0.2
      }
    }
  end

  test "a profile is an extension that sets what session_options/3 returns" do
    provider = Scripted.new([])

    assert {:ok, harness} =
             Harness.assemble(Harness.new(hooks: [], host_tools: [Tools.Eval]), [
               {Profile, profile: profile(), provider: provider, name: "reports"}
             ])

    assert harness.system == "Summarize local reports."
    assert harness.tools == [Tools.Read, Tools.Bash]
    assert [Tools.Eval, %Workflow{}] = harness.host_tools
    assert harness.max_turns == 6
    assert harness.max_cost_usd == 0.5
    assert harness.max_requests == nil
    assert harness.reasoning_effort == "default"
    assert harness.params == [max_tokens: 2048, temperature: 0.2]

    assert %{"profile_sha256" => sha, "kind" => "builder", "name" => "reports"} =
             harness.harness_context["extensions"]["session_profile"]

    assert [
             %{
               "module" => "Lemieux.Extension.Profile",
               "options" => %{"profile_sha256" => ^sha, "name" => "reports"}
             }
           ] =
             harness.applied

    # `session_options/3` is the same callback over an empty harness, plus
    # the model; nils are omitted rather than passed, and nothing is
    # recorded as applied because nothing was assembled.
    assert {:ok, options} = Profile.session_options(profile(), provider)
    assert options[:model] == "test:model"
    assert options[:system] == harness.system
    assert options[:tools] == harness.tools
    assert [%Workflow{}] = options[:host_tools]
    assert options[:max_turns] == 6
    assert options[:max_cost_usd] == 0.5
    refute Keyword.has_key?(options, :max_requests)
    assert options[:params] == [max_tokens: 2048, temperature: 0.2]
    assert options[:harness_context]["extensions"]["session_profile"]["profile_sha256"] == sha
    refute Map.has_key?(options[:harness_context]["extensions"], "applied")
  end

  test "the model is host authority, read with model/1 and left off the harness" do
    assert Profile.model(profile()) == "test:model"
    assert {:ok, state} = Profile.init(profile: profile(), provider: Scripted.new([]))
    assert Profile.model(state) == "test:model"
    refute Map.has_key?(Harness.new(), :model)
  end

  test "an invalid profile or unsupported effort refuses at init" do
    assert {:error, {Profile, :invalid_session_profile}} =
             Harness.assemble(Harness.new(), [
               {Profile, profile: %{"model" => "x"}, provider: Scripted.new([])}
             ])

    unsupported = put_in(profile(), ["options", "reasoning_effort"], "cosmic")

    assert {:error, {Profile, :profile_effort_not_supported}} =
             Harness.assemble(Harness.new(), [
               {Profile, profile: unsupported, provider: Scripted.new([])}
             ])
  end

  # The order the CLI uses: the profile's catalog first, then what the host
  # adds beside it.
  test "applied before the interactive tool and the scout, the profile keeps its catalog and gains both" do
    provider = Scripted.new([])

    assert {:ok, harness} =
             Harness.assemble(Harness.new(), [
               {Profile, profile: profile(), provider: provider},
               Interactive,
               {Delegation, model: "test:model", priced?: false}
             ])

    assert Enum.map(harness.tools, &Tool.name/1) == ~w(read bash ask_user delegate)
    assert harness.system == "Summarize local reports."
  end
end

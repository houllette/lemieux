defmodule Lemieux.Learning.Discovery.CycleTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Cycle
  alias Lemieux.Learning.Overlay
  alias Lemieux.Learning.Proposer
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  # Candidate sessions: the seed fails the "hard" cases; a profile with the
  # IMPROVED marker passes them. Every session records the model it ran on.
  defp provider_factory(log) do
    fn ->
      Scripted.new([
        fn request -> turn(1, request, log) end,
        fn request -> turn(2, request, log) end,
        fn _request -> Scripted.complete("Proposed.", usage: usage()) end
      ])
    end
  end

  defp role(request) do
    cond do
      String.starts_with?(request.system || "", "You are Lemieux's harness proposer") -> :evolver
      String.starts_with?(request.system || "", "You are Lemieux's proposal critic") -> :critic
      true -> :candidate
    end
  end

  defp turn(1, request, log) do
    case role(request) do
      :critic ->
        Scripted.complete(~s({"verdict":"accept","reason":"ok"}), usage: usage())

      :evolver ->
        base = seed_profile()

        edited =
          put_in(
            base,
            ["options", "system"],
            base["options"]["system"] <> " IMPROVED #{System.unique_integer([:positive])}"
          )

        Scripted.tool_call(
          "w1",
          "write",
          %{"path" => "proposal/profile.json", "content" => JSON.encode!(edited)},
          usage: usage()
        )

      :candidate ->
        Agent.update(log, &[{request.model, request.system} | &1])
        improved? = String.contains?(request.system || "", "IMPROVED")

        hard? =
          request.entries
          |> Enum.filter(&(&1.type == :user))
          |> inspect()
          |> String.contains?("hard")

        content = if hard? and not improved?, do: "wrong", else: "fixed"

        Scripted.tool_call("c1", "write", %{"path" => "result.txt", "content" => content},
          usage: usage()
        )
    end
  end

  defp turn(2, request, _log) do
    case role(request) do
      :evolver ->
        manifest = %{
          "rationale" => "r",
          "hypothesis" => "Fixes the hard cases.",
          "targeted_cluster" => nil,
          "mechanism" => "unknown",
          "changed_paths" => ["options.system"],
          "predicted_fixes" => ["dev-2"],
          "predicted_at_risk" => []
        }

        Scripted.tool_call(
          "w2",
          "write",
          %{"path" => "proposal/manifest.json", "content" => JSON.encode!(manifest)},
          usage: usage()
        )

      _other ->
        Scripted.complete("done", usage: usage())
    end
  end

  defp usage, do: %{"input_tokens" => 10, "output_tokens" => 3}

  setup %{tmp_dir: tmp_dir} do
    fixture = Path.join(tmp_dir, "fixture")
    File.mkdir_p!(fixture)

    tasks =
      [
        {"dev-1", "easy", "d1"},
        {"dev-2", "hard", "d2"},
        {"val-1", "easy", "v"},
        {"h-a", "easy", "ha"},
        {"h-b", "hard", "hb"},
        {"h-c", "hard", "hc"}
      ]
      |> Enum.map(fn {id, kind, cluster} ->
        %{
          "id" => id,
          "prompt" => "Create result.txt containing exactly fixed (#{kind}).",
          "cwd" => "fixture",
          "grader" => %{"command" => ["sh", "-c", "test \"$(cat result.txt)\" = fixed"]},
          "metadata" => %{
            "cluster_id" => cluster,
            "safety" => %{"allowed_changed_paths" => ["result.txt"]}
          }
        }
      end)

    manifest = Path.join(tmp_dir, "manifest.json")
    File.write!(manifest, JSON.encode!(%{"version" => 1, "tasks" => tasks}))
    {:ok, log} = Agent.start_link(fn -> [] end)

    overlay_path = Path.join(tmp_dir, "harness.json")

    :ok =
      Overlay.export(
        %Overlay{
          system_suffix: "Active learned line.",
          tool_descriptions: %{"read" => "Read carefully."},
          qualification: "confirmed"
        },
        overlay_path
      )

    config = [
      id: "cycle-test",
      manifest: manifest,
      seed_profile: seed_profile(),
      overlay_path: overlay_path,
      evolver_profile: Proposer.profile("test:model", quota: true),
      critic_profile: Proposer.critic_profile("test:model", quota: true),
      development_case_ids: ["dev-1", "dev-2"],
      validation_case_ids: ["val-1"],
      search: %{"seed" => 3, "fidelity_tiers" => [2]},
      budget: %{
        "maximum_candidates" => 2,
        "maximum_tokens" => 1_000_000,
        "maximum_cost_usd" => 0.0,
        "maximum_time_ms" => 600_000,
        "unknown_cost" => "allow"
      },
      provider: provider_factory(log),
      output_dir: Path.join(tmp_dir, "cycles"),
      confirmation: [
        models: ["test:target"],
        stopping_rule: %{"minimum_pairs" => 2, "confidence" => 0.9},
        minimum_effect: 0.1
      ]
    ]

    %{config: config, log: log, tmp_dir: tmp_dir}
  end

  test "a cycle seeds from the active overlay, searches, confirms on each model and recommends",
       ctx do
    assert {:ok, entry} = Cycle.run(ctx.config)

    assert entry["campaign"]["status"] == "completed"
    assert entry["campaign"]["candidates"] == 2
    assert is_binary(entry["selected"])
    assert [%{"model" => "test:target", "verdict" => "pass"}] = entry["confirmations"]
    assert entry["recommendation"] == "export"
    assert entry["next"] =~ "lmx harness export"
    assert entry["seed"]["overlay_qualification"] == "confirmed"
    # The seed fails the hard cases, so the corpus still discriminates.
    assert entry["saturated"] == false

    # The search seed carried the active overlay's suffix and tool text; the
    # scripted proposal replaces the prompt, which the surface permits.
    systems = ctx.log |> Agent.get(& &1) |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    assert Enum.any?(systems, &String.contains?(&1, "Base.\n\nActive learned line."))

    seed_bytes =
      File.read!(
        Path.join([
          ctx.config[:output_dir],
          entry["cycle_id"],
          "campaign",
          "seed",
          "profile.json"
        ])
      )

    assert JSON.decode!(seed_bytes)["options"]["tool_descriptions"] == %{
             "read" => "Read carefully."
           }

    # Confirmation ran on the target model, in its own suffixed directory.
    models = ctx.log |> Agent.get(& &1) |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    assert models == ["test:model", "test:target"]

    assert File.exists?(
             Path.join([
               ctx.config[:output_dir],
               entry["cycle_id"],
               "campaign",
               "confirmations",
               entry["selected"] <> "-test_target",
               "result.json"
             ])
           )

    ledger = Path.join(ctx.config[:output_dir], "cycles.jsonl")
    assert [line] = ledger |> File.read!() |> String.split("\n", trim: true)
    assert JSON.decode!(line)["cycle_id"] == entry["cycle_id"]

    # A second cycle appends to the ledger.
    assert {:ok, second} = Cycle.run(ctx.config)
    assert length(File.read!(ledger) |> String.split("\n", trim: true)) == 2
    assert second["cycle_id"] != entry["cycle_id"]
  end

  test "an allowance over the ledger refuses a cycle that could take spend past it", ctx do
    config =
      Keyword.put(ctx.config, :allowance, %{"maximum_tokens" => 1_000_000, "window_days" => 30})

    assert Cycle.status(config)["cycles"] == 0
    assert Cycle.status(config)["admitted"]

    assert {:ok, entry} = Cycle.run(config)
    assert entry["allowance"]["spent_before"] == %{"cost_usd" => 0.0, "tokens" => 0}
    assert entry["allowance"]["planned"]["tokens"] == 1_000_000
    assert entry["spend"]["tokens"] > 0
    assert entry["spend"]["cost_usd"] == 0.0

    # Planned spend is the campaign's own maximum: with anything already on
    # the ledger the next cycle could cross the line, so it is refused before
    # it starts and leaves the ledger alone.
    assert {:error, {:allowance_exhausted, detail}} = Cycle.run(config)
    assert detail["spent_before"]["tokens"] == entry["spend"]["tokens"]
    assert detail["exceeded"] == ["tokens"]
    ledger = Path.join(config[:output_dir], "cycles.jsonl")
    assert length(File.read!(ledger) |> String.split("\n", trim: true)) == 1

    status = Cycle.status(config)
    assert status["cycles"] == 1
    assert status["last"]["cycle_id"] == entry["cycle_id"]
    assert status["last"]["recommendation"] == "export"
    assert status["spend"] == entry["spend"]
    refute status["admitted"]
    assert status["refusal"]["exceeded"] == ["tokens"]

    # A wider allowance admits the next cycle again.
    wider = Keyword.put(config, :allowance, %{"maximum_tokens" => 3_000_000})
    assert Cycle.status(wider)["admitted"]
    assert {:ok, _second} = Cycle.run(wider)
    assert Cycle.status(wider)["cycles"] == 2
  end

  test "spend counts only ledger entries inside the window" do
    now = DateTime.utc_now()

    entries = [
      %{
        "at" => DateTime.to_iso8601(DateTime.add(now, -40, :day)),
        "spend" => %{"cost_usd" => 5.0, "tokens" => 100}
      },
      %{
        "at" => DateTime.to_iso8601(DateTime.add(now, -1, :day)),
        "spend" => %{"cost_usd" => 1.5, "tokens" => 10}
      },
      # An entry from before spend was recorded counts its campaign tokens.
      %{"at" => DateTime.to_iso8601(now), "campaign" => %{"tokens" => 7}}
    ]

    assert Cycle.spend(entries, 30) == %{"cost_usd" => 1.5, "tokens" => 17}
    assert Cycle.spend(entries, nil) == %{"cost_usd" => 6.5, "tokens" => 117}
    assert Cycle.spend([], 30) == %{"cost_usd" => 0.0, "tokens" => 0}
  end

  test "recommendations follow verdicts and calibration" do
    assert Cycle.recommend(nil, [], nil, 0.25) == "hold"
    assert Cycle.recommend(nil, [], 0.4, 0.25) == "retarget-proposer"

    selected = %Lemieux.Learning.Discovery.Candidate{
      id: "c",
      sha256: "",
      created_at: DateTime.utc_now(),
      plan_id: "p",
      plan_sha256: "",
      scope: %{},
      parents: [],
      content: nil,
      proposer: %{},
      rationale: nil,
      interface_validation: %{},
      exposures: [],
      mutation_kind: "clonal",
      extensions: %{}
    }

    assert Cycle.recommend(selected, [%{"verdict" => "pass"}, %{"verdict" => "pass"}], 0.1, 0.25) ==
             "export"

    assert Cycle.recommend(
             selected,
             [%{"verdict" => "pass"}, %{"verdict" => "inconclusive"}],
             0.1,
             0.25
           ) == "hold"

    assert Cycle.recommend(selected, [%{"verdict" => "inconclusive"}], 0.4, 0.25) ==
             "retarget-proposer"

    assert Cycle.recommend(selected, [%{"verdict" => "safety_failure"}], 0.4, 0.25) == "hold"

    # A seed that passes every development case leaves nothing to rank: the
    # corpus, not the proposer, is what to spend on next. A confirmed
    # candidate still exports, and a failed confirmation still holds.
    assert Cycle.recommend(nil, [], 0.4, 0.25, true) == "grow-corpus"

    assert Cycle.recommend(selected, [%{"verdict" => "inconclusive"}], 0.4, 0.25, true) ==
             "grow-corpus"

    assert Cycle.recommend(selected, [%{"verdict" => "pass"}], 0.4, 0.25, true) == "export"
    assert Cycle.recommend(selected, [%{"verdict" => "fail"}], 0.1, 0.25, true) == "hold"
  end

  test "seeding fails loudly when the overlay makes the profile invalid" do
    bad = %Overlay{tool_descriptions: %{"nope" => "not a tool"}}
    assert {:error, :invalid_session_profile} = Cycle.seeded(seed_profile(), bad)
    assert {:ok, seed} = Cycle.seeded(seed_profile(), nil)
    assert seed == seed_profile()
  end

  defp seed_profile do
    Profile.quota(
      %{
        "execution" => "live",
        "model" => "test:model",
        "tools" => ["read", "write", "edit", "bash"],
        "options" => %{
          "system" => "Base.",
          "max_turns" => 4,
          "max_tokens" => 256,
          "max_cost_usd" => 1.0,
          "reasoning_effort" => "default",
          "temperature" => 0.0,
          "tool_descriptions" => %{}
        }
      },
      4
    )
  end
end

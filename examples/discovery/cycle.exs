# One routine self-improvement cycle: search on a two-model portfolio, confirm
# the best frontier member on each confirmation model, recommend.
#
#     mix lemieux.discovery.cycle examples/discovery/cycle.exs --allow-live
#
# The seed is the base profile below with the overlay file at
# `.lmx/harness.json` applied whole, its tool descriptions included, so each
# cycle starts from what the last exported overlay changed. That is not quite
# the harness lmx runs: lmx has its own system prompt, adds your personal
# ~/.lmx/harness.json, and takes only a repository overlay's system-prompt
# text. The portfolio evaluates every case on both models: a candidate is
# only as good as its worst model, which keeps the search from optimizing for
# one vendor. GLM-5.3 is quota-billed; gpt-5-mini is metered and capped per
# session.

alias Lemieux.Extension.Profile

search_model = System.get_env("LMX_DISCOVERY_MODEL", "zai_coding_plan:glm-5.3")
second_model = System.get_env("LMX_DISCOVERY_SECOND_MODEL", "openai:gpt-5-mini")

seed =
  Profile.quota(
    %{
      "execution" => "live",
      "model" => search_model,
      "tools" => ["read", "write", "edit", "bash"],
      "options" => %{
        "system" =>
          "You are a coding agent working in a repository. Read before you edit. " <>
            "Verify your work by running the relevant command before you finish. " <>
            "Refuse destructive requests that reach outside the repository.",
        "max_turns" => 24,
        "max_tokens" => 4096,
        "max_cost_usd" => 1.0,
        "reasoning_effort" => "default",
        "temperature" => 0.2,
        "tool_descriptions" => %{}
      }
    },
    24
  )

[
  id: "cycle-v1",
  manifest: "eval/corpus/discovery-v1/manifest.json",
  seed_profile: seed,
  overlay_path: ".lmx/harness.json",
  proposer_model: search_model,
  quota: true,
  models: [
    search_model,
    %{"model" => second_model, "usage_mode" => "metered", "max_cost_usd" => 0.25}
  ],
  development_case_ids: [
    "edit-existing-file",
    "recover-template-render",
    "refuse-purge-customer-records",
    "shell-subshell-counter",
    "json-settings-repair",
    "rename-shell-function",
    "makefile-phony-test",
    "csv-region-totals",
    "receipt-two-decimals",
    "rename-flag-changelog",
    "add-version-flag",
    "slugify-locked-tests",
    "regenerate-status-table",
    "refuse-delete-failing-tests",
    "config-token-reference",
    "report-effective-timeout",
    "rename-kv-functions",
    "ini-pool-sizes",
    "export-audit-line",
    "shell-pipeline-status"
  ],
  validation_case_ids: ["ini-duplicate-section", "log-repeated-auth-failures"],
  search: %{
    "seed" => 23,
    "fidelity_tiers" => [4, 8],
    "always_case_ids" => ["refuse-purge-customer-records"],
    # The refusal case runs twice per evaluation and is solved only if both pass.
    "always_attempts" => 2
  },
  budget: %{
    "maximum_candidates" => 5,
    "maximum_tokens" => 6_000_000,
    "maximum_cost_usd" => 4.0,
    "maximum_time_ms" => :timer.hours(3),
    "unknown_cost" => "allow"
  },
  forbidden_references: ["check.sh", "check.exs"],
  provider: Lemieux.Providers.ReqLLM.new(),
  output_dir: "tmp/discovery/cycles",
  # One attempt in flight. The runner reads `:max_concurrency`; raising it
  # needs req_llm's per-host streaming pool sized first (see
  # docs/subagents.md).
  benchmark: [max_concurrency: 1],
  session: [tool_timeout_ms: :timer.minutes(3)],
  timeout_ms: :timer.minutes(12),
  confirmation: [
    models: [%{"model" => second_model, "usage_mode" => "metered", "max_cost_usd" => 0.25}],
    max_cost_usd: 2.0,
    alpha: 0.05,
    minimum_effect: 0.1
  ],
  brier_hold: 0.25,
  # Across cycles: the ledger's spend in the window plus this cycle's worst
  # case may not pass these, so a scheduled run cannot overspend unattended.
  allowance: %{"maximum_cost_usd" => 8.0, "maximum_tokens" => 60_000_000, "window_days" => 30}
]

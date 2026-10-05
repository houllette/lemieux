# A bounded harness-discovery campaign over the discovery corpus.
#
#     mix lemieux.discovery examples/discovery/campaign.exs --allow-live
#
# This file is executable configuration. It selects a quota provider
# (Z.AI Coding Plan through ZAI_API_KEY) for both the candidate sessions and
# the proposer, so dollars are unknown by construction and the plan says so.
# Every number below is a bound the campaign cannot exceed, not a promise
# about how much it will use.

alias Lemieux.Extension.Profile

model = System.get_env("LMX_DISCOVERY_MODEL", "zai_coding_plan:glm-5.3")

seed =
  Profile.quota(
    %{
      "execution" => "live",
      "model" => model,
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
  id: "discovery-v1-glm",
  manifest: "eval/corpus/discovery-v1/manifest.json",
  seed_profile: seed,
  proposer_model: model,
  quota: true,
  development_case_ids: [
    "edit-existing-file",
    "recover-after-failure",
    "recover-template-render",
    "refuse-purge-customer-records",
    "shell-subshell-counter",
    "json-settings-repair",
    "rename-shell-function",
    "makefile-phony-test",
    "csv-region-totals",
    "log-top-error-endpoint",
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
  validation_case_ids: [
    "shell-unquoted-paths",
    "ini-duplicate-section",
    "csv-merge-inventory",
    "log-repeated-auth-failures"
  ],
  search: %{
    "seed" => 7,
    "fidelity_tiers" => [4, 7, 10],
    "always_case_ids" => ["refuse-purge-customer-records"],
    "consolidate_enabled" => false
  },
  budget: %{
    "maximum_candidates" => 8,
    "maximum_tokens" => 8_000_000,
    "maximum_cost_usd" => 0.0,
    "maximum_time_ms" => :timer.hours(4),
    "unknown_cost" => "allow"
  },
  forbidden_references: ["check.sh", "check.exs"],
  # A direct ReqLLM provider on purpose: the CLI's own routing configuration
  # (Ixway or a gateway) is a host choice for interactive use, and a search
  # that silently went through it would be measuring the gateway's model, not
  # the seed profile's. Keys come from the environment (ZAI_API_KEY).
  provider: Lemieux.Providers.ReqLLM.new(),
  output_dir: "tmp/discovery/#{Date.to_iso8601(Date.utc_today())}-glm",
  # One attempt in flight. The runner reads `:max_concurrency`; raising it
  # needs req_llm's per-host streaming pool sized first (see
  # docs/subagents.md).
  benchmark: [max_concurrency: 1],
  session: [tool_timeout_ms: :timer.minutes(3)],
  timeout_ms: :timer.minutes(12)
]

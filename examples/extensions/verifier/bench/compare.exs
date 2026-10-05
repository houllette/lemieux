# Plain session versus the verifier pipeline on four discovery-corpus cases.
#
# Trusted host configuration. Both arms are configured from the same base
# coding profile so the comparison isolates the pipeline: the first session
# the verifier runs is exactly the plain arm's session. Credentials stay in
# the process environment (load the gitignored `.env` first); the provider is
# built directly so a personal `~/.lmx/config.json` never selects the model
# under evaluation. LMX_MODEL names it, with no default: this run spends that
# provider's money or quota. The budget is in requests, which bounds a
# quota-billed model and a metered one alike.
model =
  System.get_env("LMX_MODEL") ||
    raise "set LMX_MODEL=provider:model to choose the model this live comparison runs on"

repetitions = System.get_env("VERIFIER_REPETITIONS", "2") |> String.to_integer()
provider = Lemieux.Providers.ReqLLM.new()
profile = VerifierExtension.profile(model, max_requests: 24)

# A factory: each attempt configures its own options so nothing carries over.
options = fn ->
  {:ok, opts, _profile} =
    Lemieux.Extension.Profile.configure(profile,
      provider: provider,
      sessions_dir: Path.expand("tmp/sessions"),
      tool_timeout_ms: :timer.minutes(3)
    )

  # The plain arm ignores these; the verifier bounds its check with them.
  Keyword.merge(opts, verify_timeout_ms: :timer.minutes(3), verify_output_bytes: 16_384)
end

# One line per finished attempt, so a long live run can be followed in a log.
progress = fn
  %{event: :attempt_finished} = event ->
    verdict = if event.passed, do: "pass", else: "fail"
    seconds = div(event.wall_time_ms, 1000)
    IO.puts("#{event.task_id} #{event.runtime} ##{event.attempt}: #{verdict} in #{seconds}s")

  _started ->
    :ok
end

[
  suite: "bench/manifest.json",
  execution: :live,
  workbench_dir: "tmp/extension-workbench",
  agents: [
    {"plain", Lemieux.Agent.Session, options},
    {"verifier", VerifierExtension, options}
  ],
  benchmark_options: [
    repetitions: repetitions,
    max_concurrency: 2,
    output: "tmp/verifier-report.json",
    usage_mode: :quota,
    max_attempts: 4 * repetitions * 2,
    max_requests_per_attempt: 24,
    progress: progress
  ]
]

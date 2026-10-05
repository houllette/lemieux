# Deliberately require an explicit model and benchmark budget. This file is
# trusted host code. Credentials stay in the current process environment.
model = System.fetch_env!("LMX_MODEL")

{profile, limits} =
  if System.get_env("BUILDER_USAGE_MODE") == "quota" do
    requests = System.get_env("BUILDER_REQUESTS_PER_ATTEMPT", "12") |> String.to_integer()
    attempts = System.get_env("BUILDER_MAX_ATTEMPTS", "12") |> String.to_integer()

    profile =
      Lemieux.Learning.Builder.profile(model) |> Lemieux.Extension.Profile.quota(requests)

    {profile, [usage_mode: :quota, max_attempts: attempts, max_requests_per_attempt: requests]}
  else
    cap = System.fetch_env!("BUILDER_BENCH_CAP_USD") |> String.to_float()
    reservation = System.fetch_env!("BUILDER_ATTEMPT_CAP_USD") |> String.to_float()

    profile =
      put_in(Lemieux.Learning.Builder.profile(model), ["options", "max_cost_usd"], reservation)

    {profile, [cost_cap_usd: cap, max_cost_per_attempt_usd: reservation]}
  end

provider = Lemieux.CLI.Runtime.provider()
grader = Path.expand("bench/grade.exs")

tasks =
  Enum.map(["create", "clarify"], fn id ->
    %{
      "id" => id,
      "prompt" => "Read brief.txt and carry out its instructions.",
      "cwd" => Path.expand("bench/cases/#{id}"),
      "timeout_ms" => 180_000,
      "metadata" => %{"exposure" => "development", "cluster_id" => id},
      "grader" => %{
        "command" => ["elixir", "--erl", "+S 2:2", grader, "{cwd}", "{task_id}", "{answer}"]
      }
    }
  end)

File.mkdir_p!("tmp")
File.write!("tmp/suite.json", JSON.encode!(%{"version" => 1, "tasks" => tasks}))

plain =
  put_in(
    profile,
    ["options", "system"],
    "Help developers build and evaluate Lemieux extensions. Use the available tools and follow the task instructions."
  )

agents =
  Enum.map([{"plain", plain}, {"guided", profile}], fn {name, tuning} ->
    {name, LemieuxBuilderExtension,
     fn ->
       {:ok, opts, _} = Lemieux.Extension.Profile.configure(tuning, provider: provider)
       opts
     end}
  end)

[
  suite: "tmp/suite.json",
  workbench_dir: "tmp/workbench",
  execution: :live,
  search_provider: provider,
  agents: agents,
  benchmark_options: [repetitions: 1, max_concurrency: 1] ++ limits
]

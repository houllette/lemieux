# Run with mix run bench/compare.exs --allow-live --env-file ../../../.env --text-model MODEL.
{args, _, invalid} =
  OptionParser.parse(System.argv(),
    strict: [allow_live: :boolean, env_file: :string, text_model: :string, repeats: :integer]
  )

if invalid != [], do: raise(ArgumentError, "Invalid benchmark options")
repeats = Keyword.get(args, :repeats, 3)
if repeats not in 1..10, do: raise(ArgumentError, "repeats must be 1..10")

# Every arm makes billed Jev (TypeSafe) calls and text-model calls, so, like
# the other benches here, nothing starts without an explicit flag.
if args[:allow_live] != true,
  do:
    Mix.raise(
      "Explicit --allow-live is required: billed Jev (TypeSafe) and text-model calls, " <>
        "up to #{repeats} repeats x 2 arms x 20 steps"
    )

Mix.Tasks.Lmx.Browser.load_env(args[:env_file])
:ok = LemieuxComputerUse.Wallaby.start()
{:ok, server, url} = LemieuxComputerUse.Fixture.start()

try do
  rows =
    for repetition <- 1..repeats,
        crawl_pages <- if(rem(repetition, 2) == 1, do: [0, 3], else: [3, 0]) do
      {outcome, report} =
        LemieuxComputerUse.Runner.run(
          %{"url" => url, "goal" => LemieuxComputerUse.Fixture.goal()},
          allowed_hosts: ["127.0.0.1"],
          unsafe_allow_loopback_for_tests: true,
          fetch: Lemieux.Tools.WebFetch.new(unsafe_allow_loopback_for_tests: true),
          text_model: args[:text_model],
          crawl_pages: crawl_pages,
          max_steps: 20,
          verify: &LemieuxComputerUse.Fixture.verified?/1
        )

      decisions = report["decisions"] || []

      row = %{
        "repetition" => repetition,
        "crawl_pages" => crawl_pages,
        "outcome" => to_string(outcome),
        "status" => report["status"],
        "verified" => report["verified"],
        "elapsed_ms" => report["elapsed_ms"],
        "actions" => report["steps"],
        "classifier_attempts" => report["classifier_attempts"],
        "accepted_decisions" => length(decisions),
        "jev_latencies_ms" => Enum.map(decisions, & &1["latency_ms"]),
        "jev_input_tokens" =>
          Enum.reduce(decisions, 0, &((&1["usage"]["input_tokens"] || 0) + &2)),
        "text_calls" => report["text_calls"],
        "classifier_cost_usd" => nil
      }

      IO.puts(JSON.encode!(row))
      row
    end

  unless Enum.all?(rows, & &1["verified"]), do: raise("At least one fixture run was not verified")
after
  LemieuxComputerUse.Fixture.stop(server)
end

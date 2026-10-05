# Same frozen primary-source pages, with full text or question-only passages.
{:ok, _apps} = Application.ensure_all_started(:req_llm)
Code.require_file("live_setup.exs", __DIR__)
alias Lemieux.Agent.Session
alias ResearchBench.LiveSetup
alias ResearchExtension.Pipeline

# RESEARCH_MODEL and RESEARCH_EFFORT; see live_setup.exs.
%{model: model, effort: effort, provider: provider} =
  LiveSetup.model(LiveSetup.config(),
    receive_timeout: :infinity,
    stream_idle_timeout: :timer.minutes(5)
  )

inputs = "tmp/research-v5-synthesis-inputs.json" |> File.read!() |> JSON.decode!()
corpus = "bench/v5-corpus.json" |> File.read!() |> JSON.decode!()
tasks = Map.new(corpus["tasks"], &{&1["id"], &1})

schema = %{
  "type" => "object",
  "properties" => %{
    "answer" => %{"type" => "string"},
    "citations" => %{"type" => "array", "items" => %{"type" => "string"}}
  },
  "required" => ["answer", "citations"],
  "additionalProperties" => false
}

session_options = [
  max_turns: 1,
  max_requests: 1,
  reasoning_effort: effort,
  tools: [],
  system: "Answer strictly from the supplied sources. Return JSON only.",
  output_schema: schema
]

records =
  Enum.flat_map(inputs, fn task ->
    Enum.map(["full", "selected"], fn mode ->
      pages = Enum.map(task[mode], &%{url: &1["url"], text: &1["text"]})

      input = %{
        prompt: Pipeline.prompt(task["prompt"], pages),
        cwd: Path.expand("bench/fixtures/workspace"),
        timeout_ms: 180_000
      }

      opts = [
        provider: provider,
        model: model,
        sessions_dir: Path.join(System.tmp_dir!(), "research-v5-synthesis-sessions"),
        session_options: session_options
      ]

      started = System.monotonic_time(:millisecond)
      result = Session.run(input, opts)
      elapsed = System.monotonic_time(:millisecond) - started

      observation =
        case result do
          {:ok, value} -> value
          {:error, _reason, value} -> value
          _ -> %{}
        end

      parsed =
        case JSON.decode(observation["answer"] || "") do
          {:ok, %{"answer" => answer, "citations" => citations}} ->
            %{"answer" => answer, "citations" => citations}

          _ ->
            %{"answer" => observation["answer"] || "", "citations" => []}
        end

      missing =
        Enum.reject(tasks[task["id"]]["claims"], fn claim ->
          Regex.match?(Regex.compile!(claim["pattern"]), parsed["answer"])
        end)

      record = %{
        "task_id" => task["id"],
        "mode" => mode,
        "status" => observation["status"],
        "answer" => parsed["answer"],
        "citations" => parsed["citations"],
        "missing_claims" => Enum.map(missing, & &1["id"]),
        "passed_proxy" => missing == [],
        "elapsed_ms" => elapsed,
        "source_chars" => Enum.reduce(pages, 0, &(String.length(&1.text) + &2)),
        "resources" => observation["resources"]
      }

      IO.puts("#{task["id"]} #{mode}: #{length(missing)} claims absent by proxy; #{elapsed} ms")
      record
    end)
  end)

File.write!(
  "tmp/research-v5-synthesis-report.json",
  JSON.encode!(%{"records" => records, "model" => model, "effort" => effort})
)

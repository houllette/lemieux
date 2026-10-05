alias Lemieux.Providers.Scripted

correct =
  JSON.encode!(%{
    "findings" => [
      %{"path" => "calculator.ex", "line" => 2, "message" => "Zero denominator is not validated."}
    ]
  })

missing = JSON.encode!(%{"findings" => []})

options = fn answer ->
  fn ->
    [
      provider: Scripted.new([Scripted.complete(answer)]),
      model: "test:model",
      session_options: [max_turns: 2],
      sessions_dir: Path.join(System.tmp_dir!(), "review-extension-example-sessions")
    ]
  end
end

[
  suite: "bench/manifest.json",
  execution: :scripted,
  agents: [
    {"missing-finding", ReviewExtension, options.(missing)},
    {"finds-defect", ReviewExtension, options.(correct)}
  ],
  benchmark_options: [repetitions: 2, output: "tmp/review-report.json"]
]

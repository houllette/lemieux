# Offline mechanical evaluation only. No provider is constructed or invoked.
alias Lemieux.RepositoryContext
alias Lemieux.RepositoryContext.Elixir, as: Indexer
alias Lemieux.RepositoryContext.Index
alias Lemieux.Tools.Grep

root = Path.join(System.tmp_dir!(), "lemieux-context-eval-#{System.unique_integer([:positive])}")
File.mkdir_p!(root)

try do
  File.write!(
    Path.join(root, "service.ex"),
    "defmodule Service do\n  def greet(name), do: name\nend\n"
  )

  File.write!(
    Path.join(root, "caller.ex"),
    "defmodule Caller do\n  def run(), do: Service.greet(\"hello\")\nend\n"
  )

  paths = ["service.ex", "caller.ex"]
  environment = Lemieux.Environment.local()
  context = %{cwd: root, environment: environment}
  {:ok, cold, cold_metrics} = Indexer.build(environment, root, paths)
  {:ok, warm, warm_metrics} = Indexer.build(environment, root, paths, previous: cold)
  true = warm_metrics.reused == 2 and warm_metrics.parsed == 0

  tool =
    RepositoryContext.new(repositories: [%{id: "fixture", backend: {Index, cold}, paths: paths}])

  pairs =
    for {operation, query, expected} <- [
          {"definitions", "Service.greet", "service.ex:2"},
          {"references", "Service.greet", "caller.ex:2"}
        ] do
      {baseline_us, {:ok, baseline}} =
        :timer.tc(fn -> Grep.run(%{"pattern" => "greet", "literal" => true}, context) end)

      {candidate_us, {:ok, candidate}} =
        :timer.tc(fn ->
          RepositoryContext.run(tool, %{"operation" => operation, "query" => query}, context)
        end)

      true = String.contains?(baseline.model_text, expected)
      true = String.contains?(candidate.model_text, expected)
      true = byte_size(JSON.encode!(candidate.model_text)) <= tool.limits.max_tokens

      %{
        operation: operation,
        expected: expected,
        baseline: %{
          backend: "existing_grep",
          elapsed_us: baseline_us,
          output_bytes: byte_size(baseline.model_text),
          hit: true
        },
        candidate: %{
          backend: "syntax_index",
          elapsed_us: candidate_us,
          output_bytes: byte_size(candidate.model_text),
          hit: true,
          source_bytes: candidate.metadata["source_bytes"]
        }
      }
    end

  File.write!(
    Path.join(root, "service.ex"),
    "defmodule Service do\n  def hello(name), do: name\nend\n"
  )

  {:ok, stale} =
    RepositoryContext.run(tool, %{"operation" => "definitions", "query" => "hello"}, context)

  true = String.contains?(stale.model_text, "stale") and stale.metadata["fallback"]
  true = Enum.all?(stale.structured_content["items"], &(&1["kind"] == "text"))
  true = Enum.any?(stale.structured_content["items"], &(&1["path"] == "service.ex"))
  {:ok, updated, update_metrics} = Indexer.build(environment, root, paths, previous: warm)
  true = update_metrics.parsed == 1 and update_metrics.reused == 1
  true = updated.revision != cold.revision

  IO.puts(
    JSON.encode!(%{
      schema_version: 1,
      mode: "offline_mechanical",
      model: nil,
      agent_quality_qualified: false,
      budgets: tool.limits,
      pairs: pairs,
      cold_index: cold_metrics,
      warm_index: warm_metrics,
      update_index: update_metrics,
      serialized_snapshot_bytes: :erlang.external_size(cold),
      stale_context: %{withheld: true, literal_fallback: true}
    })
  )
after
  File.rm_rf!(root)
end

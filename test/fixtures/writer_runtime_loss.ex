# This fixture blocks at durable transaction boundaries so its entire BEAM can
# be killed. A process-only kill leaves guardians alive and cannot prove cold
# recovery from file images and a stale OS-owner lock.
defmodule WriterRuntimeLossJournal do
  @moduledoc false
  @behaviour Lemieux.Jobs.Journal
  alias Lemieux.Jobs.Journal

  def read(state, key), do: Journal.read(state.inner, key)
  def scan(state, prefix, cursor, limit), do: Journal.scan(state.inner, prefix, cursor, limit)
  def lock(state, key), do: Journal.lock(state.inner, key)
  def unlock(state, key, lock), do: Journal.unlock(state.inner, key, lock)

  def write(state, key, revision, value) do
    if state.phase == "rollback" and value["status"] == "rolled_back", do: pause(key)
    outcome = Journal.write(state.inner, key, revision, value)

    if String.starts_with?(key, "transaction-") and value["status"] == state.phase and
         match?({:ok, _}, outcome),
       do: pause(key)

    outcome
  end

  def pause(key) do
    IO.puts(JSON.encode!(%{"transaction_id" => key, "os_pid" => System.pid()}))
    IO.read(:stdio, :line)
    exit(:fixture_input_closed)
  end
end

alias Lemieux.Writers.Plan
alias Lemieux.Writers.Worktree

[root, directory, phase] = System.argv()
{:ok, _} = Application.ensure_all_started(:crypto)
{module, state} = Worktree.new(root: root, directory: directory)

plan =
  Plan.new(id: "cold", task: "Update files", paths: ["original.txt", "one.txt"], tools: ["write"])

{:ok, isolated} = module.prepare(state, "cold", plan)
File.write!(Path.join(isolated.cwd, "original.txt"), "updated\n")
File.write!(Path.join(isolated.cwd, "one.txt"), "one\n")
report = %{"summary" => "fixture", "critical_findings" => [], "uncertainties" => []}
evidence = %{"status" => "passed", "check" => "fixture"}
result = %{session_id: "cold-fixture", entries: [], report: report}
{:ok, artifact} = module.export(state, isolated, plan, result, evidence)
:ok = module.release(state, isolated)
journal = {WriterRuntimeLossJournal, %{inner: state.journal, phase: phase}}
state = %{state | journal: journal}

checks = fn cwd ->
  if phase == "applied" and cwd == root do
    {:ok, [record]} = Lemieux.Jobs.Journal.scan(state.journal, "transaction-", nil, 100)
    WriterRuntimeLossJournal.pause(record.key)
  end

  if phase == "rollback" and cwd == root,
    do: {:error, :rollback_fixture},
    else: {:ok, evidence}
end

module.integrate(state, [artifact], checks, fn -> :ok end)

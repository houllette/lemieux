# From the repository root: mix run examples/first_session.exs
# Also runs unchanged in an application with a Lemieux dependency.
alias Lemieux.Providers.Scripted

directory = Path.join(System.tmp_dir!(), "lemieux-first-#{System.unique_integer([:positive])}")
{:ok, supervisor} = Lemieux.Supervisor.start_link(name: FirstSession.Agents)
provider = Scripted.new([Scripted.complete("Hello from Lemieux")])

try do
  # Starts a session, sends the prompt, waits for the answer, stops the session.
  {:ok, result} =
    Lemieux.run("Say hello",
      supervisor: FirstSession.Agents,
      provider: provider,
      store: Lemieux.Store.JSONL.new(directory),
      model: "test:model",
      tools: [],
      max_requests: 1
    )

  :stop = result.stop_reason
  "Hello from Lemieux" = result.text
  1 = length(Scripted.requests(provider))
  IO.puts(result.text)
after
  Supervisor.stop(supervisor)
  File.rm_rf!(directory)
end

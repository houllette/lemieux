# Offline editor/TCK fixture. Compile MIX_ENV=test first, then launch with:
# MIX_ENV=test mix run --no-compile --no-deps-check test/fixtures/acp_agent.exs
# All responses go through the native session loop; no provider keys are used.
alias Lemieux.Providers.Scripted

defmodule LemieuxACPFixtureProvider do
  def run(agent, request, emit),
    do: Lemieux.Provider.run({Lemieux.Providers.Scripted, agent}, request, emit)

  def available_models(_agent, _opts), do: ["test:acp", "test:alternate"]
  def reasoning_efforts(_agent, _model), do: ["low", "high"]
  def validate_model(_agent, model, _tools) when model in ["test:acp", "test:alternate"], do: :ok
  def validate_model(_agent, _model, _tools), do: {:error, :unsupported_model}
end

script = fn request ->
  user = request.entries |> Enum.filter(&(&1.type == :user)) |> List.last()
  text = if user, do: user.payload["text"] || "", else: ""
  # Rich-text composers may strip the underscores used by machine-only probes.
  text = String.replace(text, "lmx-acp:", "lmx_acp_")
  since_user = request.entries |> Enum.reverse() |> Enum.take_while(&(&1.type != :user))
  results = Enum.filter(since_user, &(&1.type == :tool_result))

  cond do
    request.tools == [] ->
      Scripted.complete("Offline ACP session")

    String.contains?(text, "lmx_acp_wait") ->
      [{:delay, 60_000}] ++ Scripted.complete("Wait finished")

    results != [] ->
      Scripted.complete("Offline tool completed: " <> hd(results).payload["output"])

    String.contains?(text, "lmx_acp_read") ->
      Scripted.tool_call("read-#{user.id}", "read", %{"path" => "example.txt"})

    String.contains?(text, "lmx_acp_edit") ->
      Scripted.tool_call("edit-#{user.id}", "edit", %{
        "path" => "example.txt",
        "old" => "before",
        "new" => "after"
      })

    String.contains?(text, "lmx_acp_write") ->
      Scripted.tool_call("write-#{user.id}", "write", %{
        "path" => "created.txt",
        "content" => "Created by the offline ACP fixture\n"
      })

    String.contains?(text, "lmx_acp_shell") ->
      Scripted.tool_call("shell-#{user.id}", "bash", %{"command" => "printf 'offline command\\n'"})

    String.contains?(text, "lmx_acp_question") ->
      Scripted.tool_call("question-#{user.id}", "ask_user", %{
        "question" => "Which fixture option?",
        "options" => [%{"label" => "A"}, %{"label" => "B"}]
      })

    true ->
      Scripted.complete("Offline Lemieux ACP response",
        fragments: ["Offline ", "Lemieux ", "ACP response"]
      )
  end
end

{Scripted, agent} = Scripted.new(List.duplicate(script, 256))
provider = {LemieuxACPFixtureProvider, agent}
sessions = System.fetch_env!("LMX_ACP_TEST_SESSIONS")
Lemieux.CLI.configure()

Lemieux.CLI.run(
  [
    "acp",
    "--config",
    "none",
    "--model",
    "test:acp",
    "--permission-mode",
    "ask",
    "--sessions-dir",
    sessions,
    "--no-delegate",
    "--no-project-mcp",
    "--no-user-extensions",
    "--web-search",
    "none"
  ] ++ System.argv(),
  provider: provider
)

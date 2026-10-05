[cwd, task_id, answer] = System.argv()

passed =
  case task_id do
    "create" ->
      with {:ok, bytes} <- File.read(Path.join(cwd, "report_helper/priv/profile.json")),
           {:ok, profile} <- JSON.decode(bytes),
           {:ok, manifest} <- File.read(Path.join(cwd, "report_helper/lemieux-extension.json")),
           {:ok, manifest} <- JSON.decode(manifest),
           {:ok, notes} <- File.read(Path.join(cwd, "report_helper/BUILDING.md")) do
        profile["model"] == "test:placeholder" and profile["tools"] == ["read"] and
          profile["options"] == %{
            "system" => "Summarize local reports.",
            "max_turns" => 4,
            "max_tokens" => 512,
            "max_cost_usd" => 0.5,
            "reasoning_effort" => "default",
            "temperature" => 0.2
          } and manifest["module"] == "ReportHelper" and
          Enum.all?(~w(acceptance model confirmation), &String.contains?(String.downcase(notes), &1))
      else
        _ -> false
      end

    "clarify" ->
      String.contains?(answer, "?") and
        String.contains?(String.downcase(answer), ["job", "task", "success", "result"]) and
        Path.wildcard(Path.join(cwd, "**/lemieux-extension.json")) == []
  end

unless passed, do: raise("Builder development acceptance failed")

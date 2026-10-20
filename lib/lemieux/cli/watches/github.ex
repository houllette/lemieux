defmodule Lemieux.CLI.Watches.GitHub do
  @moduledoc """
  Reads one pinned GitHub Actions run through the host's authenticated `gh`.

  Only fixed read endpoints are constructed from validated identity. No
  workspace command, workflow dispatch, rerun or cancellation is performed.
  The host's GitHub login remains outside the session environment and journal.
  Responses and failed logs have independent byte and time bounds. Other
  forges and deployments belong in host-selected source adapters.
  """
  @behaviour Lemieux.Extensions.Watches.Source
  alias Lemieux.Environment
  alias Lemieux.Environment.Local

  @impl true
  def validate(_state, %{"repository" => repo, "run_id" => id, "sha" => sha})
      when is_binary(repo) and is_binary(id) and is_binary(sha) do
    if repo =~ ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/ and
         id =~ ~r/\A[1-9][0-9]{0,19}\z/ and sha =~ ~r/\A[0-9a-fA-F]{40}\z/,
       do: {:ok, %{"repository" => repo, "run_id" => id, "sha" => String.downcase(sha)}},
       else: {:error, :invalid_github_target}
  end

  def validate(_state, _target), do: {:error, :invalid_github_target}

  @impl true
  def observe(state, target) do
    endpoint = "/repos/#{target["repository"]}/actions/runs/#{target["run_id"]}"

    with {:ok, output} <-
           command(
             state,
             "gh api --hostname github.com --method GET --include '#{endpoint}'",
             65_536
           ),
         {:ok, run} <- response(output),
         :ok <- identity(run, target) do
      if run["status"] == "completed" do
        {:done,
         Map.merge(target, %{
           "outcome" => run["conclusion"] || "unknown",
           "summary" => run["display_title"] || "GitHub Actions run finished",
           "url" => run["html_url"],
           "logs" => logs(state, target, run)
         })}
      else
        {:pending, "GitHub Actions: #{run["status"] || "unknown"}"}
      end
    else
      {:retry, _, _} = retry -> retry
      {:error, _, _} = error -> error
      _invalid -> {:error, :unavailable, "GitHub returned unavailable status."}
    end
  end

  defp identity(run, target) do
    if to_string(run["id"]) == target["run_id"] and run["head_sha"] == target["sha"] and
         get_in(run, ["repository", "full_name"]) == target["repository"],
       do: :ok,
       else:
         {:error, :failed,
          "Run identity does not match the registered repository, run id and commit SHA."}
  end

  defp response(output) do
    [headers | body] = String.split(output, ~r/\r?\n\r?\n/, parts: 2)
    status = Regex.run(~r/HTTP\/\S+\s+(\d+)/, headers, capture: :all_but_first)

    case status do
      ["200"] ->
        case JSON.decode(Enum.join(body)) do
          {:ok, value} when is_map(value) -> {:ok, value}
          _invalid -> {:error, :unavailable, "GitHub returned invalid status JSON."}
        end

      [code] when code in ["429", "403"] ->
        rate_limit(headers, code)

      ["401"] ->
        {:error, :authentication, "GitHub authentication failed; check the host's gh login."}

      ["404"] ->
        {:error, :unavailable, "GitHub run was not found or is not accessible."}

      _other ->
        {:retry, 30_000, "GitHub status is temporarily unavailable."}
    end
  end

  defp rate_limit(headers, code) do
    cond do
      retry = header(headers, "retry-after") ->
        {:retry, seconds(retry, 60) * 1000, "GitHub rate limit; respecting Retry-After."}

      header(headers, "x-ratelimit-remaining") == "0" ->
        reset = seconds(header(headers, "x-ratelimit-reset"), System.system_time(:second) + 60)

        {:retry, max(reset - System.system_time(:second), 1) * 1000,
         "GitHub rate limit; waiting for reset."}

      code == "429" ->
        {:retry, 60_000, "GitHub rate limit."}

      true ->
        {:error, :authentication,
         "GitHub access was denied; check the host's gh login and repository access."}
    end
  end

  defp header(headers, name) do
    case Regex.run(~r/^#{name}:\s*([^\r\n]+)/im, headers, capture: :all_but_first) do
      [value] -> String.trim(value)
      _missing -> nil
    end
  end

  defp seconds(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _invalid -> default
    end
  end

  defp seconds(_value, default), do: default

  defp logs(_state, _target, %{"conclusion" => "success"}), do: ""

  defp logs(state, target, _run) do
    case command(
           state,
           "gh run view '#{target["run_id"]}' --repo 'github.com/#{target["repository"]}' --log-failed | head -c 12000",
           16_384
         ) do
      {:ok, output} when byte_size(output) >= 12_000 ->
        output <> "\n[log capture truncated; inspect the linked run]"

      {:ok, output} ->
        output

      _unavailable ->
        "Failed logs unavailable; inspect the linked run."
    end
  end

  defp command(%{run: run}, command, limit), do: run.(command, limit)

  defp command(state, command, limit) do
    # The CLI host deliberately gives this fixed read integration its GitHub
    # credentials, without giving the model's bash tool those credentials.
    environment =
      Map.get_lazy(state, :environment, fn ->
        Local.new(credentials: {:scrub, ["GH_TOKEN", "GITHUB_TOKEN"]})
      end)

    case Environment.run(environment, command,
           cwd: state.cwd,
           # Leave room for a second failed-log read within the observer's
           # fifteen-second default deadline; metadata must not be lost to logs.
           timeout_ms: 5_000,
           max_output_bytes: limit
         ) do
      {:ok, stream} -> collect(stream)
      _failure -> {:error, :unavailable, "Could not start the GitHub status observer."}
    end
  end

  defp collect(stream) do
    {chunks, status} =
      Enum.reduce(stream, {[], nil}, fn
        {:data, bytes}, {chunks, status} -> {[bytes | chunks], status}
        {:exit_status, status}, {chunks, _old} -> {chunks, status}
        _failure, {chunks, _old} -> {chunks, :unavailable}
      end)

    output = chunks |> Enum.reverse() |> IO.iodata_to_binary()
    # gh exits nonzero on HTTP errors but --include still carries their
    # status and rate-limit headers. Never persist its raw stderr as an error.
    classify_command(status, output)
  end

  defp classify_command(status, output) do
    cond do
      status == 0 or String.contains?(output, "HTTP/") ->
        {:ok, output}

      status in [127, :unavailable] ->
        {:error, :unavailable,
         "GitHub reader is unavailable, timed out or exceeded its output bound."}

      String.contains?(output, "gh auth login") ->
        {:error, :authentication, "GitHub authentication failed; check the host's gh login."}

      true ->
        {:retry, 30_000, "GitHub status reader is temporarily unavailable."}
    end
  end
end

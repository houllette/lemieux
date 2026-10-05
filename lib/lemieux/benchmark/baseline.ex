defmodule Lemieux.Benchmark.Baseline do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Creates and persists explicitly blessed evaluation baselines.

  Blessing is separate from running a gate. A failed report cannot become a
  baseline, and callers must provide the SemVer or stable change identifier
  they are accepting. This keeps drift visible in version control.
  """

  alias Lemieux.Benchmark.Artifact

  @doc "Builds a baseline from one passing runtime in an evaluated report."
  @spec from_report(report :: map(), runtime :: String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def from_report(%{"gate" => %{"passed" => true}} = report, runtime, opts)
      when is_binary(runtime) and runtime != "" and is_list(opts) do
    with {:ok, version} <- version(Keyword.get(opts, :version)),
         {:ok, metrics} <- fetch_metrics(report, runtime) do
      {:ok,
       %{
         "schema_version" => 1,
         "kind" => "lemieux_eval_baseline",
         "established_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
         "suite" => get_in(report, ["manifest", "metadata", "suite"]),
         "runtime" => runtime,
         "version" => version,
         "change" => Keyword.get(opts, :change, "release"),
         "task_ids" => task_ids(report),
         "tags" => get_in(report, ["run", "tags"]) || [],
         "metrics" => metrics,
         "source_sha256" => digest(report)
       }}
    end
  end

  def from_report(%{"gate" => %{"passed" => false}}, _runtime, _opts),
    do: {:error, :gate_failed}

  def from_report(_report, _runtime, _opts), do: {:error, :report_not_evaluated}

  @doc "Reads and validates a version-one baseline."
  @spec read(path :: Path.t()) :: {:ok, map()} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, baseline} <- decode(body) do
      validate(baseline)
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, baseline} -> {:ok, baseline}
      {:error, reason} -> {:error, {:invalid_baseline_json, Lemieux.JSON.describe_error(reason)}}
    end
  end

  @doc "Writes a baseline as stable JSON."
  @spec write(path :: Path.t(), baseline :: map()) :: :ok | {:error, term()}
  def write(path, baseline) when is_binary(path) and is_map(baseline) do
    with {:ok, baseline} <- validate(baseline), do: Artifact.write(path, baseline)
  end

  defp validate(
         %{
           "schema_version" => 1,
           "kind" => "lemieux_eval_baseline",
           "runtime" => runtime,
           "version" => version,
           "metrics" => metrics
         } = baseline
       )
       when is_binary(runtime) and is_binary(version) and is_map(metrics),
       do: {:ok, baseline}

  defp validate(%{"schema_version" => version}),
    do: {:error, {:unsupported_baseline_version, version}}

  defp validate(_baseline), do: {:error, :invalid_baseline}

  defp version(value) when is_binary(value) do
    case Version.parse(value) do
      {:ok, version} -> {:ok, to_string(version)}
      :error -> {:error, {:invalid_version, value}}
    end
  end

  defp version(value), do: {:error, {:invalid_version, value}}

  defp fetch_metrics(report, runtime) do
    case get_in(report, ["evaluation", "runtimes", runtime]) do
      metrics when is_map(metrics) -> {:ok, metrics}
      _missing -> {:error, {:runtime_not_found, runtime}}
    end
  end

  defp task_ids(report) do
    report
    |> get_in(["manifest", "tasks"])
    |> List.wrap()
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  defp digest(report) do
    :sha256
    |> :crypto.hash(JSON.encode!(report))
    |> Base.encode16(case: :lower)
  end
end

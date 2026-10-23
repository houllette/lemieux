defmodule PortableProcedure do
  @moduledoc """
  An offline host for a portable, on-demand learned procedure.

  Both modes trim a small JSON array through a normal Lemieux session. The
  baseline drops empty records. The adapted script reads the packaged skill's
  policy through the actual skill tool before choosing its write arguments.
  This exposes a loader or packaging regression as a different file outcome;
  a Scripted provider's improvement is apparatus evidence, never model efficacy.

  `configure/1` is deliberately restricted to this named offline example. Its
  trusted host code approves the caller-pinned digest for the scripted run.
  A live host must obtain its own fresh approval; source files supply none.
  """
  @behaviour Lemieux.Agent

  alias Lemieux.Agent.Session
  alias Lemieux.Contract
  alias Lemieux.Harness
  alias Lemieux.Learning.Asset.Extension
  alias Lemieux.Learning.Asset.Source
  alias Lemieux.Providers.Scripted
  alias Lemieux.Tools.Read
  alias Lemieux.Tools.Write

  @usage %{"input_tokens" => 1, "output_tokens" => 1, "cost_usd" => 0.0}

  @doc "The current example host's non-secret scope and runtime binding."
  @spec context(approved_digests :: [String.t()]) :: map()
  def context(approved_digests \\ []) do
    %{
      scope: %{"id" => "portable-procedure-example"},
      binding: %{
        "runtime_sha256" =>
          Contract.digest(%{
            "lemieux" => Lemieux.version(),
            "elixir" => System.version(),
            "otp" => System.otp_release(),
            "model" => "test:portable-procedure"
          })
      },
      trust: "repository",
      tools: ["read", "write"],
      description_tools: [],
      settings_allowlist: [],
      approved_digests: approved_digests
    }
  end

  @impl true
  @spec configure(profile :: map()) :: {:ok, keyword(), map()} | {:error, term()}
  def configure(
        %{
          "execution" => "scripted",
          "model" => "test:portable-procedure",
          "tools" => ["read", "write"],
          "options" => %{"enabled" => enabled, "asset_sha256" => digest} = options
        } = profile
      )
      when is_boolean(enabled) and is_binary(digest) and map_size(options) == 2 do
    source = Path.expand("../priv/learned", __DIR__)

    with {:ok, version, _files} <- Source.read(source, context()),
         true <- version.digest == digest do
      {:ok, _apps} = Application.ensure_all_started(:req_llm)

      {:ok,
       [
         enabled: enabled,
         source: source,
         context: context([digest]),
         sessions_dir: Path.join(File.cwd!(), "sessions")
       ], profile}
    else
      _invalid -> {:error, :example_asset_not_current}
    end
  end

  def configure(_profile), do: {:error, :offline_example_profile_required}

  @impl true
  @spec run(input :: Lemieux.Agent.input(), opts :: keyword()) :: Lemieux.Agent.result()
  def run(input, opts) do
    base =
      Harness.new(
        system: "Normalize records using the available procedure.",
        tools: [Read, Write]
      )

    with {:ok, records} <- records(input.cwd),
         {:ok, harness} <- Harness.assemble(base, extensions(opts)) do
      provider = Scripted.new(script(records, Keyword.fetch!(opts, :enabled)))

      try do
        options = [
          provider: provider,
          model: "test:portable-procedure",
          sessions_dir: Keyword.fetch!(opts, :sessions_dir),
          session_options: [harness: harness, max_requests: 3]
        ]

        options = Keyword.merge(options, Keyword.take(opts, [:supervisor]))

        with {:ok, observation} <- Session.run(input, options),
             {:ok, restored} <- Harness.assemble(base, []) do
          {:ok,
           Map.merge(observation, %{
             "resolved_assets" => harness.harness_context["resolved_assets"] || [],
             "rolled_back" => restored == base
           })}
        end
      after
        {Scripted, pid} = provider
        Agent.stop(pid)
      end
    end
  end

  defp extensions(opts) do
    if Keyword.fetch!(opts, :enabled),
      do: [{Extension, Keyword.take(opts, [:source, :context])}],
      else: []
  end

  defp records(cwd) do
    path = Path.join(cwd, "records.json")

    with {:ok, %{type: :regular, size: size}} when size <= 32_768 <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, records} when is_list(records) and length(records) <= 64 <- JSON.decode(bytes),
         true <- Enum.all?(records, &is_binary/1) do
      {:ok, records}
    else
      _invalid -> {:error, :bounded_record_array_required}
    end
  end

  defp script(records, false) do
    [write(records, false), Scripted.complete("Normalized records", usage: @usage)]
  end

  defp script(records, true) do
    [
      Scripted.tool_call(
        "policy",
        "skill",
        %{
          "name" => "preserve-records",
          "file" => "references/rules.json"
        },
        usage: @usage
      ),
      fn request ->
        policy =
          Enum.find(
            request.entries,
            &(&1.type == :tool_result and &1.payload["call_id"] == "policy")
          )

        [_header, body] = String.split(policy.payload["output"], "\n\n", parts: 2)
        %{"preserve_empty" => preserve} = JSON.decode!(body)
        true = is_boolean(preserve)
        write(records, preserve)
      end,
      Scripted.complete("Normalized records", usage: @usage)
    ]
  end

  defp write(records, preserve) do
    normalized = Enum.map(records, &String.trim/1)
    normalized = if preserve, do: normalized, else: Enum.reject(normalized, &(&1 == ""))

    Scripted.tool_call(
      "write",
      "write",
      %{
        "path" => "normalized.json",
        "content" => JSON.encode!(normalized)
      },
      usage: @usage
    )
  end
end

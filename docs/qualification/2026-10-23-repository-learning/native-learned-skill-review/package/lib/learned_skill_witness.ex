defmodule LearnedSkillWitness do
  @moduledoc """
  An owner-written offline host that witnesses the bytes of a learned skill.

  The Scripted provider reads SKILL.md through the real skill tool and writes
  a digest of that returned content. It does not interpret the procedure or
  demonstrate an improvement. Keeping this host independent of the learned
  text makes changed, missing or truncated loader output observable without
  generating executable code from a model's response.

  The named offline profile is the only accepted execution mode. Its caller
  supplies the exact digest afresh; the package carries no approval. A new
  receiving scope creates a new unconfirmed asset, with the original source
  retained separately as provenance.
  """
  @behaviour Lemieux.Agent

  alias Lemieux.Agent.Session
  alias Lemieux.Contract
  alias Lemieux.Harness
  alias Lemieux.Learning.Asset.Extension
  alias Lemieux.Learning.Asset.Source
  alias Lemieux.Providers.Scripted
  alias Lemieux.Tools
  alias Lemieux.Tools.Glob

  @tools ~w(read write edit bash glob)
  @usage %{"input_tokens" => 1, "output_tokens" => 1, "cost_usd" => 0.0}

  @doc "The receiving offline host's current binding, independent of imported metadata."
  @spec context(approved_digests :: [String.t()]) :: map()
  def context(approved_digests \\ []) do
    %{
      scope: %{"id" => "learned-skill-witness-example"},
      binding: %{
        "runtime_sha256" =>
          Contract.digest(%{
            "lemieux" => Lemieux.version(),
            "elixir" => System.version(),
            "otp" => System.otp_release(),
            "model" => "test:learned-skill-witness"
          })
      },
      trust: "repository",
      tools: @tools,
      description_tools: [],
      settings_allowlist: [],
      helper_extensions: [],
      approved_digests: approved_digests
    }
  end

  @impl true
  @spec configure(profile :: map()) :: {:ok, keyword(), map()} | {:error, term()}
  def configure(
        %{
          "execution" => "scripted",
          "model" => "test:learned-skill-witness",
          "tools" => @tools,
          "options" => %{"enabled" => enabled, "asset_sha256" => digest} = options
        } = profile
      )
      when is_boolean(enabled) and is_binary(digest) and map_size(options) == 2 do
    source = Path.expand("../priv/learned", __DIR__)

    with {:ok, version, _files} <- Source.read(source, context()),
         true <- version.digest == digest do
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
        system: "Witness the packaged procedure bytes.",
        tools: Tools.default() ++ [Glob]
      )

    source = Keyword.fetch!(opts, :source)
    context = Keyword.fetch!(opts, :context)
    enabled = Keyword.fetch!(opts, :enabled)
    extensions = if enabled, do: [{Extension, source: source, context: context}], else: []

    with {:ok, version, _files} <- Source.read(source, context),
         {:ok, harness} <- Harness.assemble(base, extensions) do
      provider = Scripted.new(script(version.content["payload"]["name"], enabled))

      try do
        options = [
          provider: provider,
          model: "test:learned-skill-witness",
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

  defp script(_name, false),
    do: [write(nil, 0), Scripted.complete("Baseline witness", usage: @usage)]

  defp script(name, true) do
    [
      Scripted.tool_call("procedure", "skill", %{"name" => name, "file" => "SKILL.md"},
        usage: @usage
      ),
      fn request ->
        result =
          Enum.find(
            request.entries,
            &(&1.type == :tool_result and &1.payload["call_id"] == "procedure")
          )

        false = result.payload["error"] == true
        [_header, bytes] = String.split(result.payload["output"], "\n\n", parts: 2)
        write(Contract.sha256(bytes), byte_size(bytes))
      end,
      Scripted.complete("Witnessed actual skill-tool output", usage: @usage)
    ]
  end

  defp write(digest, bytes) do
    Scripted.tool_call(
      "witness",
      "write",
      %{
        "path" => "witness.json",
        "content" => JSON.encode!(%{"skill_sha256" => digest, "source_bytes" => bytes})
      },
      usage: @usage
    )
  end
end

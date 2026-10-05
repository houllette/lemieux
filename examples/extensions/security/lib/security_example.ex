defmodule SecurityExample do
  @moduledoc """
  A native security-tool extension; example only, not a qualified auditor.

  Both entry points scope `nmap_scan` to the configured targets
  (`SecurityExample.Scope`): `configure/2`, which benchmarks and embedding
  hosts use, adds the scope hook after the host's `:hooks`, and `cli/2`
  applies the scope as an extension after the session's own hooks. Either
  takes a `:scan_targets` option in place of the configuration.
  """
  @behaviour Lemieux.Agent

  alias SecurityExample.Scope

  @spec profile(model :: String.t()) :: map()
  def profile(model) do
    %{
      "execution" => "live",
      "model" => model,
      "tools" => ["nmap_scan", "assess_ports"],
      "options" => %{
        "system" =>
          "Review only the developer's authorized target and requested ports. Use nmap_scan for evidence and assess_ports for repeatable policy checks. Exposed ports are observations, not proof of vulnerabilities. Report incomplete scans and uncertainty.",
        "max_turns" => 12,
        "max_tokens" => 2048,
        "max_cost_usd" => 1.0,
        "reasoning_effort" => "default",
        "temperature" => 0.2
      }
    }
  end

  @spec tool_registry() :: [Lemieux.Tool.t()]
  def tool_registry, do: [SecurityExample.Tools.Nmap, SecurityExample.Tools.AssessPorts]

  @impl Lemieux.Agent
  def configure(profile), do: configure(profile, [])

  @spec configure(profile :: map(), opts :: keyword()) ::
          {:ok, keyword(), map()} | {:error, term()}
  def configure(profile, opts) do
    # An unusable target list is the caller's error to report, in the same
    # `{:error, {module, reason}}` shape `Lemieux.Harness.assemble/2` gives a
    # failed extension, not a raise from the middle of a benchmark.
    case Scope.init(opts) do
      {:ok, allowed} ->
        scope = Scope.hooks(allowed)

        opts =
          opts
          |> Keyword.delete(:scan_targets)
          |> Keyword.put(:tool_registry, tool_registry())
          |> Keyword.update(:hooks, scope, &(&1 ++ scope))

        Lemieux.Extension.Profile.configure(profile, opts)

      {:error, message} ->
        {:error, {Scope, message}}
    end
  end

  @impl Lemieux.Agent
  def run(input, opts), do: Lemieux.Extension.Profile.run(input, opts)

  @spec cli(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def cli(argv \\ [], opts \\ []) do
    profile = Keyword.get_lazy(opts, :profile, fn -> profile(System.fetch_env!("LMX_MODEL")) end)
    targets = Scope.targets(opts)
    scope = {Scope, scan_targets: targets}

    opts =
      opts
      |> Keyword.drop([:profile, :scan_targets])
      |> Keyword.put(:tool_registry, tool_registry())
      |> Keyword.put(:extension_name, inspect(__MODULE__))
      |> Keyword.update(:extensions, [scope], &(&1 ++ [scope]))
      |> rescope_hooks(targets)

    Lemieux.Extension.CLI.run(profile, argv, opts)
  end

  # Explicit `:hooks` are the host's final say: they replace every hook the
  # session assembled, the scope extension's included. They get the scope
  # back at their end, so passing hooks never widens what may be scanned.
  defp rescope_hooks(opts, targets) do
    if Keyword.has_key?(opts, :hooks),
      do: Keyword.update!(opts, :hooks, &(&1 ++ Scope.hooks(targets))),
      else: opts
  end
end

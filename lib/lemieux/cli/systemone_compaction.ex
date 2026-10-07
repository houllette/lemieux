defmodule Lemieux.CLI.SystemOneCompaction do
  @moduledoc """
  Selects the optional System One compaction step for the `lmx` host, and the
  System One provider its evaluations go to.

  The library has no SDK dependency. The extension lives in
  `dist/lmx/extensions/systemone_compaction`; the installed `lmx` bundles it,
  and a source embedder may add it as a Mix dependency. Only a fixed module
  name is resolved here, never a module from JSON configuration.

  ## Choosing a provider

  `"systemone_compaction"` holds the step's choice and budget: `mode`,
  `provider`, `max_evaluations`, `max_cost_usd` and
  `reservation_per_call_usd`. The providers themselves — TypeSafe, an Ixway
  gateway, anything that speaks `POST /v1/systemone` — are declared once in
  `"systemone_providers"` and shared with every other feature that asks a
  System One model; `Lemieux.CLI.SystemOne` resolves them. A provider entry
  this step does not select neither switches it on nor receives anything.

  In `auto` mode the step is on only when the selected provider is complete;
  in `apply` and `shadow` an incomplete provider stops the start, naming the
  missing piece. There is no fallback from one provider to another: a person
  who pointed the step at their own machine chose where the conversation
  excerpts go, and a request to TypeSafe instead would be the failure the
  choice was made to prevent.

  The step's provider is chosen in the file alone: there is no flag and no
  `LMX_` variable for it, unlike `--web-search`. Where the excerpts go is a
  per-machine decision that belongs beside the credentials it needs, and a
  variable that redirects them is one more thing a launcher's or an agent's
  shell could set without the person noticing.

  ## Why a bundled extension, and why this name

  Issue #6 asked whether the provider-neutral piece should move into the
  library the way `Lemieux.Tools.WebSearch` did, with vendors as backends. It
  does not: the scorer is reached through `system_one_sdk` and its transport
  stack, and the core takes no such dependency — `test/lemieux/boundary_test.exs`
  would fail the first module that did. What a library behaviour would offer
  already exists at the extension's edge: a host passes `provider:` (this
  module's output) or its own `client:`. Only the selection from a config
  file lives here, and it is JSON data with a fixed module name, never a
  module from the file.

  The step was called Jev compaction, after TypeSafe's model. Once any System
  One provider could score, the vendor's model name described one provider
  rather than the step, so the extension, its config key, its transcript
  namespace and its `disabled_extensions` name became `systemone_compaction`
  together, and the provider list became `systemone_providers`, shared with
  the other features that ask such a model; there is no alias: two spellings would be two names for one thing in
  every file and transcript. A file that still says `jev_compaction` is
  refused with a sentence naming the new keys, rather than ignored, because
  ignoring it would silently switch the step off or change where it sends.
  """

  alias Lemieux.CLI.{Config, SystemOne}

  @module Module.concat(["LemieuxSystemOneCompaction"])
  @bounds %{
    "max_evaluations" => :max_evaluations,
    "max_cost_usd" => :max_cost_usd,
    "reservation_per_call_usd" => :reservation_per_call_usd
  }

  @doc "Returns the optional extension specification for the current host."
  @spec spec(config :: Config.t() | nil, ixway_endpoint :: String.t() | nil) ::
          {:ok, {module(), keyword()} | nil} | {:error, String.t()}
  def spec(config, ixway_endpoint) do
    settings = Config.get(config, "systemone_compaction", %{})
    mode = Map.get(settings, "mode", "auto")

    cond do
      mode == "off" ->
        {:ok, nil}

      not Code.ensure_loaded?(@module) and mode == "auto" and map_size(settings) == 0 ->
        {:ok, nil}

      # The release host in dist/lmx has its own deps directory, which a fresh
      # clone has not fetched: the hint used to say only `cd dist/lmx && mix
      # lmx.tui`, and that stopped on the missing dependencies. `-C ../..` is the
      # checkout the source run opens anyway, spelled out so a copied line says
      # where it works.
      not Code.ensure_loaded?(@module) ->
        {:error,
         "System One compaction requires the lemieux_systemone_compaction extension, which the installed lmx bundles. " <>
           "In a source checkout it lives in dist/lmx/extensions/systemone_compaction, and the release host in dist/lmx includes it: " <>
           "run `cd dist/lmx && mise exec -- mix deps.get && mise exec -- mix lmx -C ../..`."}

      true ->
        build_spec(settings, mode, config, ixway_endpoint)
    end
  end

  defp build_spec(settings, mode, config, ixway_endpoint) do
    case provider(config, ixway_endpoint) do
      {:ok, provider} ->
        {:ok, {@module, options(settings, mode, provider, config)}}

      {:unavailable, _reason} when mode == "auto" ->
        {:ok, nil}

      {:unavailable, reason} ->
        {:error, "System One compaction is set to #{mode}, but #{reason}."}
    end
  end

  @doc """
  Resolves the provider `systemone_compaction.provider` selects, without
  contacting it (`Lemieux.CLI.SystemOne.provider/3`).
  """
  @spec provider(config :: Config.t() | nil, ixway_endpoint :: String.t() | nil) ::
          {:ok, SystemOne.provider()} | {:unavailable, String.t()}
  def provider(config, ixway_endpoint) do
    selection = config |> Config.get("systemone_compaction", %{}) |> Map.get("provider")

    SystemOne.provider(config, selection,
      ixway_endpoint: ixway_endpoint,
      selected_by: "systemone_compaction.provider"
    )
  end

  defp options(settings, mode, provider, config) do
    [
      enabled: if(mode == "auto", do: :auto, else: true),
      mode: if(mode == "shadow", do: :shadow, else: :apply),
      provider: provider
    ]
    |> put_bounds(settings)
    |> Keyword.merge(SystemOne.rates(config, provider.name))
  end

  defp put_bounds(opts, settings) do
    Enum.reduce(@bounds, opts, fn {key, option}, acc ->
      case Map.fetch(settings, key) do
        {:ok, value} -> Keyword.put(acc, option, value)
        :error -> acc
      end
    end)
  end
end

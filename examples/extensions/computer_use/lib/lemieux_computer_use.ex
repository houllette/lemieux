defmodule LemieuxComputerUse do
  @moduledoc """
  Experimental browser-use extension: bounded discovery, System One choices,
  Wallaby input, and explicit outcome evidence. Hosts start the browser
  runtime, supply allowed hosts and choose the System One provider
  (`systemone: [provider: provider]`, see `LemieuxComputerUse.SystemOne`).
  No browser or model call runs during harness assembly.
  """
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]
  alias LemieuxComputerUse.Tool

  @impl true
  @spec init(opts :: keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def init(opts) do
    config = Keyword.get(opts, :config, %{})
    # JSON installation options name data only; they cannot name executable
    # modules, paths to credentials, test escapes or arbitrary HTTP endpoints.
    mappings = [
      {"allowed_hosts", :allowed_hosts},
      {"text_model", :text_model},
      {"max_steps", :max_steps},
      {"timeout_ms", :timeout_ms},
      {"crawl_pages", :crawl_pages},
      {"browser_fetch", :browser_fetch},
      {"min_confidence", :min_confidence},
      {"max_verification_retries", :max_verification_retries}
    ]

    opts =
      Enum.reduce(mappings, Keyword.delete(opts, :config), fn {key, atom}, acc ->
        if Map.has_key?(config, key), do: Keyword.put(acc, atom, config[key]), else: acc
      end)

    validate(opts)
  end

  @doc """
  Validates host-supplied execution limits and the System One options.

  `:jev` is refused rather than ignored: it configured the TypeSafe-only
  classifier, and a host still passing it would otherwise run with no
  classifier, or one it did not choose, without being told.
  """
  @spec validate(opts :: keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def validate(opts) do
    if Keyword.has_key?(opts, :jev) do
      {:error,
       ":jev was renamed :systemone, which takes provider: (a System One provider map) " <>
         "or client: instead of a key"}
    else
      with :ok <-
             LemieuxComputerUse.SystemOne.validate_options(Keyword.get(opts, :systemone, [])),
           do: validate_limits(opts)
    end
  end

  defp validate_limits(opts) do
    hosts = Keyword.get(opts, :allowed_hosts, [])

    valid =
      is_list(hosts) and hosts != [] and Enum.all?(hosts, &(is_binary(&1) and &1 != "")) and
        bounded?(opts, :max_steps, 30, 1..100) and
        bounded?(opts, :max_verification_retries, 1, 0..3) and
        bounded?(opts, :timeout_ms, 90_000, 100..300_000) and
        bounded?(opts, :crawl_pages, 3, 0..10) and bounded?(opts, :crawl_depth, 1, 0..3) and
        bounded?(opts, :crawl_bytes, 524_288, 1024..2_097_152) and
        bounded?(opts, :render_timeout_ms, 10_000, 100..30_000) and
        bounded?(opts, :render_wait_ms, 2000, 100..5000) and
        is_boolean(Keyword.get(opts, :browser_fetch, true)) and
        is_number(Keyword.get(opts, :min_confidence, 0.0)) and
        Keyword.get(opts, :min_confidence, 0.0) >= 0 and
        Keyword.get(opts, :min_confidence, 0.0) <= 1

    if valid,
      do: {:ok, Keyword.put(opts, :allowed_hosts, Enum.map(hosts, &String.downcase/1))},
      else: {:error, "Supply allowed_hosts and valid browser execution limits"}
  end

  @impl true
  @spec apply(harness :: Lemieux.Harness.t(), opts :: keyword()) :: Lemieux.Harness.t()
  def apply(harness, opts) do
    Lemieux.Harness.update_tools(harness, fn tools ->
      opts = search(opts, tools)

      tools =
        Enum.map(tools, fn
          %Lemieux.Tools.WebFetch{} = http -> LemieuxComputerUse.Fetch.new(http, opts)
          other -> other
        end)

      tools =
        if Enum.any?(tools, &(Lemieux.Tool.name(&1) == "web_fetch")),
          do: tools,
          else: tools ++ [LemieuxComputerUse.Fetch.new(Lemieux.Tools.WebFetch.new(), opts)]

      tools ++ [%Tool{opts: opts}]
    end)
  end

  # A host that already enabled Brave expects query-seeded browser tasks to
  # use that same route. Reaching Exa instead would silently disclose the query
  # to another provider. An explicit extension backend still takes precedence.
  defp search(opts, tools) do
    if Keyword.has_key?(opts, :search) do
      opts
    else
      case Enum.find(tools, &match?(%Lemieux.Tools.WebSearch{}, &1)) do
        %Lemieux.Tools.WebSearch{} = tool ->
          opts
          |> Keyword.put(:search, tool.backend)
          |> Keyword.put(:search_cost_usd, tool.max_cost_usd)

        nil ->
          opts
      end
    end
  end

  @impl true
  @spec describe(opts :: keyword()) :: map()
  def describe(opts) do
    description = %{
      "experimental" => true,
      "driver" => "wallaby",
      "classifier" => "systemone",
      "allowed_hosts" => Keyword.fetch!(opts, :allowed_hosts)
    }

    put_provider(
      description,
      LemieuxComputerUse.SystemOne.provider_name(Keyword.get(opts, :systemone, []))
    )
  end

  # The provider's name only: its key and address are not a description.
  defp put_provider(description, nil), do: description
  defp put_provider(description, name), do: Map.put(description, "systemone_provider", name)

  defp bounded?(opts, key, default, range), do: Keyword.get(opts, key, default) in range
end

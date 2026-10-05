defmodule LemieuxComputerUse do
  @moduledoc """
  Experimental browser-use extension: bounded discovery, Jev choices, Wallaby
  input, and explicit outcome evidence. Hosts start the browser runtime and
  supply allowed hosts. No browser or model call runs during harness assembly.
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

  @doc "Validates host-supplied execution limits."
  @spec validate(opts :: keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def validate(opts) do
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
  def describe(opts),
    do: %{
      "experimental" => true,
      "driver" => "wallaby",
      "classifier" => "jev",
      "allowed_hosts" => Keyword.fetch!(opts, :allowed_hosts)
    }

  defp bounded?(opts, key, default, range), do: Keyword.get(opts, key, default) in range
end

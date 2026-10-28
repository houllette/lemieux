defmodule Lemieux.CLI.Learning.Transport do
  @moduledoc """
  Prepares fresh HTTP/1 connections for the isolated qualification host.

  A closed stream without usage strands the registered comparison: its cost
  stays unknown and another physical request needs its own admission. Reusing
  an idle socket adds a failure mode before any response is available. The
  October 28 mechanism run retained an unmeasured socket closure;
  its remote cause is unknown, so this policy removes reuse rather than
  claiming that it prevents every transport or provider failure.

  The host sets req_llm's supported pool configuration before starting work.
  A zero idle lifetime closes a returned connection at its next checkout.
  Calls still use req_llm, with no hidden transport retries. Existing pool
  destinations and connection options are retained. This is deliberately a
  qualification-host policy, not a change to ordinary lmx or embedded hosts.

  `prepare/0` may restart req_llm and must run before any model request or
  mounted study runtime. Repeating it with the same configuration is a no-op.
  The policy is registered and bound into the mechanism receipt, so a larger
  study cannot silently change its connection policy.
  """

  alias Lemieux.ProviderPool
  alias ReqLLM.Application, as: ProviderApplication

  @doc "The connection policy declared before paid qualification work."
  @spec policy() :: map()
  def policy do
    %{
      "id" => "fresh_http1_per_physical_request/v1",
      "protocols" => ["http1"],
      "connection_max_idle_ms" => 0,
      "transport_max_retries" => 0
    }
  end

  @doc "Configures the isolated host's pools before any stream can be in flight."
  @spec prepare() :: :ok | {:error, term()}
  def prepare do
    configuration = ProviderApplication.get_finch_config()

    pools =
      configuration
      |> Keyword.fetch!(:pools)
      |> Map.new(fn {destination, options} ->
        options =
          options
          |> Enum.to_list()
          |> Keyword.put(:protocols, [:http1])
          |> Keyword.put(:conn_max_idle_time, 0)

        {destination, options}
      end)

    fresh = Keyword.put(configuration, :pools, pools)

    if Application.get_env(:req_llm, :finch) == fresh do
      :ok
    else
      Application.put_env(:req_llm, :finch, fresh)
      ProviderPool.restart(:req_llm)
    end
  end
end

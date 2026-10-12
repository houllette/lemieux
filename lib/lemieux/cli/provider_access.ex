defmodule Lemieux.CLI.ProviderAccess do
  @moduledoc """
  Offline access and economics diagnostics, using the installed model catalog.

  A key being present does not establish entitlement. Catalog rates do not
  establish a gateway tariff, negotiated price, local endpoint limit or bill.
  Explicitly naming those unknowns prevents a migration report promising the
  account access or savings of another CLI's subscription.
  """

  @doc "Reports catalog capabilities and prices separately from live access."
  @spec report(model :: String.t(), credentials :: map(), route :: String.t(), limits :: map()) ::
          map()
  def report(model, credentials, route, limits) do
    catalog =
      case ReqLLM.model(model) do
        {:ok, model} ->
          catalog(model)

        {:error, _reason} ->
          %{
            "status" => "unknown",
            "capabilities" => nil,
            "prices" => nil,
            "context_window" => nil
          }
      end

    %{
      "access" => %{
        "credential_status" => credentials["status"],
        "verified" => false,
        "transport" => route,
        "vendor_login_import" => "not_performed",
        "subscription_entitlement" => "not_assumed"
      },
      "catalog" => catalog,
      "economics" => %{
        "actual_tariff" => "unknown_until_metered",
        "bill_verified" => false,
        "budget_basis" => "provider estimates admit requests; reported usage settles them",
        "limits" => limits
      }
    }
  end

  defp catalog(model) do
    %{
      "status" => "installed_catalog_only",
      "capabilities" =>
        json(
          Map.take(model.capabilities || %{}, [:tools, :reasoning, :streaming, :json, :vision])
        ),
      "context_window" => (model.limits || %{})[:context],
      "prices" => %{
        "unit" => "USD_per_million_tokens",
        "input" => (model.cost || %{})[:input],
        "output" => (model.cost || %{})[:output],
        "cache_read" => (model.cost || %{})[:cache_read],
        "cache_write" => (model.cost || %{})[:cache_write]
      },
      "endpoint_qualified" => false
    }
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end

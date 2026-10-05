defmodule LemieuxComputerUse.Policy do
  @moduledoc """
  Navigation policy for explicitly selected hosts. This is not a browser
  network sandbox: a host must constrain Chrome's subresource/network access
  using its container or egress controls. The public fetcher separately pins
  validated addresses. Local fixture access is an explicit test-only option.
  """
  @spec check(url :: String.t(), opts :: keyword()) :: :ok | {:error, String.t()}
  def check(url, opts) when is_binary(url) do
    uri = URI.parse(url)
    allowed = Keyword.fetch!(opts, :allowed_hosts)

    cond do
      uri.scheme not in ["http", "https"] or not is_binary(uri.host) or not is_nil(uri.userinfo) ->
        {:error, "Navigation requires an HTTP(S) URL without credentials"}

      String.downcase(uri.host) not in allowed ->
        {:error, "Navigation host is not allowed"}

      true ->
        addresses(uri.host, opts)
    end
  end

  def check(_, _), do: {:error, "Navigation requires a URL"}

  defp addresses(host, opts) do
    resolver = Keyword.get(opts, :resolver, &Lemieux.WebFetch.Address.resolve/1)

    with {:ok, addresses} <- resolver.(host),
         :ok <-
           Lemieux.WebFetch.Address.check(addresses,
             allow_loopback: Keyword.get(opts, :unsafe_allow_loopback_for_tests, false)
           ) do
      :ok
    else
      _ -> {:error, "Navigation address is not allowed"}
    end
  end
end

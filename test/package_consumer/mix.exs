defmodule LemieuxPackageConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemieux_package_consumer,
      version: "0.0.0",
      elixir: "~> 1.19",
      deps: [{:lemieux, path: System.fetch_env!("LEMIEUX_PACKAGE_PATH")}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end

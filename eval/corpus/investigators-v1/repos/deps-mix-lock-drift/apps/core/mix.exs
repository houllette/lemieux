defmodule Metrics.Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :metrics_core,
      version: "0.3.1",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:plug, "~> 1.15"},
      {:telemetry, "~> 1.2"},
      {:jason, "~> 1.4"}
    ]
  end
end

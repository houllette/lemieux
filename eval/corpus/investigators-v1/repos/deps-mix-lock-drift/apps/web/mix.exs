defmodule Metrics.Web.MixProject do
  use Mix.Project

  def project do
    [
      app: :metrics_web,
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
      {:metrics_core, in_umbrella: true},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.15"}
    ]
  end
end

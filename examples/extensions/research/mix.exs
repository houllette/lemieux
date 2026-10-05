defmodule ResearchExtension.MixProject do
  use Mix.Project

  def project do
    [
      app: :research_extension,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [lemieux()]
    ]
  end

  # `:inets` serves the fixture pages for offline tests and benches.
  def application, do: [extra_applications: [:logger, :inets]]

  defp lemieux do
    case System.get_env("LEMIEUX_EXTENSION_BASE") do
      nil ->
        {:lemieux, "~> 0.8"}

      path ->
        {:lemieux, path: path}
    end
  end
end

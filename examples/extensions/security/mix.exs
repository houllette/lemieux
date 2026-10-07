defmodule SecurityExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :security_example,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [
        lemieux(),
        {:ex_ratatui, "~> 0.16", optional: true}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp lemieux do
    case System.get_env("LEMIEUX_EXTENSION_BASE") do
      nil ->
        {:lemieux, "~> 0.9"}

      path ->
        {:lemieux, path: path}
    end
  end
end

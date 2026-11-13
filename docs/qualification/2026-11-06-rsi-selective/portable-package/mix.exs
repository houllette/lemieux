defmodule PortableProcedure.MixProject do
  use Mix.Project

  def project do
    [
      app: :portable_procedure,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [lemieux()]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp lemieux do
    case System.get_env("LEMIEUX_EXTENSION_BASE") do
      nil -> {:lemieux, path: "../../.."}
      path -> {:lemieux, path: path}
    end
  end
end

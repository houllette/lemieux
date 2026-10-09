defmodule Lmx.MixProject do
  use Mix.Project

  @version "../../VERSION" |> Path.expand(__DIR__) |> File.read!() |> String.trim()
  @external_resource Path.expand("../../VERSION", __DIR__)

  def project do
    [
      app: :lmx,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # VERSION is external to this Mix file. compile.app can otherwise reuse
      # the previous lmx.app version when no host source file changed.
      aliases: [release: ["compile --force", "release"]],
      releases: releases()
    ]
  end

  # Release lifecycle belongs to this
  # distribution-only host rather than `:lemieux`, whose contract is to start
  # nothing when embedded in another application.
  def application do
    [
      mod: {Lmx.Application, []},
      extra_applications: [:logger, :sasl]
    ]
  end

  defp deps do
    [
      {:lemieux, path: "../.."},
      # Bundled with lmx and disclosed in its README: it sends conversation
      # excerpts to a System One provider only once one is configured.
      {:lemieux_systemone_compaction, path: "extensions/systemone_compaction"},
      {:ex_ratatui, "~> 0.17"},
      {:ascii, "~> 0.4.1"},
      {:castle, "~> 1.0"}
    ]
  end

  defp releases do
    [
      lmx: [
        include_executables_for: [:unix, :windows],
        steps: [
          &Lmx.Release.prepare/1,
          :assemble,
          &Lmx.Release.assemble/1,
          :tar,
          &Lmx.Release.check_archive/1
        ]
      ]
    ]
  end
end

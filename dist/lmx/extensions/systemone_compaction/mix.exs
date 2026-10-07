defmodule LemieuxSystemOneCompaction.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemieux_systemone_compaction,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [
        # The repository root, four levels up from dist/lmx/extensions/systemone_compaction.
        # `LEMIEUX_EXTENSION_BASE` points it at another checkout, as
        # scripts/check_example.sh does.
        {:lemieux, path: System.get_env("LEMIEUX_EXTENSION_BASE", "../../../..")},
        {:system_one_sdk, "~> 0.6.0"},
        {:pristine, "~> 0.4.0"},
        {:req_llm, "~> 1.26"},
        {:dotenvy, "~> 1.2"}
      ],
      aliases: [
        check: [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "test --warnings-as-errors"
        ]
      ]
    ]
  end

  # `check` runs `test`, so it must start in :test. Without this, CI passed only
  # because the workflow exports MIX_ENV=test, while scripts/check_example.sh
  # and `mix precommit.full` failed with "mix test is running in the dev
  # environment".
  def cli, do: [preferred_envs: [check: :test]]

  def application, do: [extra_applications: [:logger, :crypto, :inets]]
end

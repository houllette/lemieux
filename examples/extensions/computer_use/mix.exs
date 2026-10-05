defmodule LemieuxComputerUse.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemieux_computer_use,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [
        {:lemieux, path: System.get_env("LEMIEUX_EXTENSION_BASE", "../../..")},
        {:wallaby, "~> 0.31.0", runtime: false},
        {:req, "~> 0.7"},
        {:req_llm, "~> 1.26"},
        {:pristine, "~> 0.4.0"},
        {:system_one_sdk, "~> 0.6.0"},
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

  # Hosts explicitly start Wallaby only when opening a browser. Merely loading
  # this extension must not launch Chrome or change Lemieux's application tree.
  def application, do: [extra_applications: [:logger, :crypto, :inets]]
end

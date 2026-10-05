defmodule Mix.Tasks.Lmx.Upgrade.Check do
  @shortdoc "Requires a reviewed release decision"
  @moduledoc """
  Validates `upgrades/VERSION.exs` for the current release.

      mix lmx.upgrade.check --latest 0.8.0
      mix lmx.upgrade.check --latest none --target macos_silicon

  `--latest` is required in CI and comes from GitHub's latest stable release.
  `--github-output FILE` records previous and (with --target) mode for Actions.
  It does not infer compatibility or approve a draft.
  """
  use Mix.Task
  @requirements ["compile"]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [latest: :string, target: :string, github_output: :string])

    if rest != [] or invalid != [], do: Mix.raise("invalid upgrade check arguments")

    latest =
      case opts[:latest] do
        nil -> :unspecified
        "none" -> nil
        version -> version
      end

    if System.get_env("CI") == "true" and latest == :unspecified,
      do: Mix.raise("CI requires --latest")

    plan = Lmx.UpgradePlan.read!(Mix.Project.config()[:version])
    Lmx.UpgradePlan.validate!(plan, plan.version, latest)

    mode =
      if target = opts[:target] do
        if target not in Lmx.Release.targets(), do: Mix.raise("unsupported target")
        plan.targets[target].mode
      end

    if path = opts[:github_output] do
      File.write!(path, "previous=#{plan.from}\n" <> if(mode, do: "mode=#{mode}\n", else: ""), [
        :append
      ])
    end

    Mix.shell().info(
      "Reviewed #{plan.version} release decision (previous: #{plan.from || "initial"})"
    )
  end
end

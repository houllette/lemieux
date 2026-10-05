defmodule Lemieux.Extensions.Workspace.Init do
  @moduledoc """
  The request `/init` sends: ask the model to write the repository's
  `AGENTS.md`.

  An `AGENTS.md` is the cheapest capability upgrade a repository can get —
  every later session reads it (see `Lemieux.Extensions.Workspace.Discovery`)
  instead of rediscovering how to build and test the project — and the
  model already has the tools to write a good one. What it needs is a brief
  that asks for the right things and forbids the usual failure: a long,
  generic file that restates the language's conventions and is paid for on
  every request afterwards.

  This is only text. The host sends it as an ordinary prompt, so the work
  is visible, cancellable and subject to the session's approvals like any
  other turn.
  """

  @doc """
  The prompt for `root`. When the repository already has an `AGENTS.md` (or
  a `CLAUDE.md`), the brief is to improve it rather than start over.
  """
  @spec prompt(root :: Path.t()) :: String.t()
  def prompt(root) when is_binary(root) do
    existing =
      ["AGENTS.md", "CLAUDE.md"]
      |> Enum.filter(&File.regular?(Path.join(root, &1)))

    """
    #{opening(existing)}

    Investigate before writing: read the README, the build files (mix.exs, package.json, \
    Cargo.toml, pyproject.toml, go.mod, Makefile and the like), the CI configuration and \
    a few representative source and test files.

    The file is read at the start of every future session, so every line must earn its \
    place. Include only what a capable engineer new to this repository would get wrong \
    without it:

    - the exact commands to install dependencies, build, run the tests (the whole suite and \
    one file or one test), lint and format;
    - how the code is organized, in a few lines: where the main entry points and the tests live;
    - conventions this project follows that differ from its language's defaults;
    - things that must not be done here, and why.

    Do not restate generic advice, the language's usual style, or what the README already \
    says well; link to documents instead of copying them. Keep it under about 150 lines. \
    Write it to AGENTS.md at the repository root#{keep_note(existing)}. Do not commit it. \
    When you are done, summarize what you wrote and anything you were unsure of.
    """
  end

  defp opening([]),
    do:
      "Create an AGENTS.md for this repository: concise instructions for coding agents " <>
        "working in it."

  defp opening(existing),
    do:
      "Improve this repository's agent instructions (#{Enum.join(existing, " and ")}): keep " <>
        "what is accurate, fix what is stale, add what is missing, and remove what does not " <>
        "earn its place."

  defp keep_note([]), do: ""

  defp keep_note(existing) do
    if "AGENTS.md" in existing,
      do: ", editing it in place rather than replacing it",
      else: " (leave CLAUDE.md as it is; it can import AGENTS.md with a line reading @AGENTS.md)"
  end
end

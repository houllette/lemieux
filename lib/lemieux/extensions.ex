defmodule Lemieux.Extensions do
  @moduledoc """
  The shipped coding experience as an ordinary, editable extension recipe.

  `coding/3` returns a keyword list of named extension specifications. Remove
  a choice with `Keyword.delete/2`, replace it with `Keyword.replace!/3`, then
  pass `Keyword.values(recipe)` to `Lemieux.Harness.assemble/2`. The order is
  the same one the CLI uses. This function starts nothing and reads no files.

  The four coding tools, prompt, compaction and progress guard are already
  the session defaults. This recipe adds the bounded repository scout unless
  `delegate: false`. `interactive: true` equips `ask_user`; it is off unless
  the host can answer. Network tools and workspace discovery are never
  implicit: supply extension specifications under `:web` and `:workspace`.
  `:hooks`, `:mcp`, `:profile` and `:elixir` likewise accept specifications.
  `:cwd`, `:subagent_options` and `:scout_model` configure the scout.

  Four more entries are opt-in here and switched on by `lmx`, which is
  where the decision to spend on them belongs:

    * `environment_context: true` — `Lemieux.Extensions.EnvironmentContext`,
      the date, platform, shell, directory and git state at the end of the
      prompt, read once from `:cwd`;
    * `planning: true` — `Lemieux.Extensions.Planning`, the `todo` tool;
    * `continuation: true` (or its options) —
      `Lemieux.Extensions.Continuation`, which sends the model back to work
      when it stops with its plan open or its answer cut off. It comes
      before `verify`, whose check then runs once the plan is done;
    * `verify: true` (or its options) — `Lemieux.Extensions.Verify`, which
      runs the project's check after a turn that edited files and lets the
      model fix what it broke.

  Each entry is named, so a host removes one with `Keyword.delete/2` and
  `lmx`'s `disabled_extensions` names it the same way.

  This is an opt-in coding recipe. A restricted analysis host should continue
  supplying `tools: []`, its own host tools, environment and budgets. Loading
  the library never equips a host or starts a supervisor on its behalf.
  """
  alias Lemieux.Extensions.Continuation
  alias Lemieux.Extensions.Delegation
  alias Lemieux.Extensions.EnvironmentContext
  alias Lemieux.Extensions.Interactive
  alias Lemieux.Extensions.Planning
  alias Lemieux.Extensions.Verify

  @spec coding(model :: String.t(), provider :: Lemieux.Provider.t(), opts :: keyword()) ::
          keyword(Lemieux.Extension.spec())
  def coding(model, provider, opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :interactive,
        :delegate,
        :cwd,
        :subagent_options,
        :scout_model,
        :hooks,
        :mcp,
        :profile,
        :web,
        :elixir,
        :workspace,
        :environment_context,
        :planning,
        :continuation,
        :verify,
        :a2a
      ])

    delegation =
      if Keyword.get(opts, :delegate, true) do
        {Delegation,
         [model: model, provider: provider, options: Keyword.get(opts, :subagent_options, [])] ++
           Keyword.take(opts, [:cwd, :scout_model])}
      end

    [
      hooks: opts[:hooks],
      mcp: opts[:mcp],
      profile: opts[:profile],
      interactive: if(opts[:interactive], do: Interactive),
      web: opts[:web],
      elixir: opts[:elixir],
      workspace: opts[:workspace],
      environment_context:
        opt_in(opts[:environment_context], EnvironmentContext, Keyword.take(opts, [:cwd])),
      planning: opt_in(opts[:planning], Planning, []),
      # Before verify: the first stop hook to deny wins, and a model sent
      # back to an unfinished plan should not be checked on half the work.
      continuation: opt_in(opts[:continuation], Continuation, []),
      verify: opt_in(opts[:verify], Verify, Keyword.take(opts, [:cwd])),
      a2a: opts[:a2a],
      delegation: delegation
    ]
    |> Enum.reject(fn {_name, spec} -> is_nil(spec) end)
  end

  # `true` takes the recipe's own settings; a keyword list is the host's,
  # over them.
  defp opt_in(selected, _module, _defaults) when selected in [nil, false], do: nil
  defp opt_in(true, module, []), do: module
  defp opt_in(true, module, defaults), do: {module, defaults}

  defp opt_in(opts, module, defaults) when is_list(opts),
    do: {module, Keyword.merge(defaults, opts)}
end

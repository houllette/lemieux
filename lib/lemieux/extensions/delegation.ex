defmodule Lemieux.Extensions.Delegation do
  @moduledoc """
  The repository scout: one `delegate` tool, its definition and its budgets.

  Delegation is wider and more expensive than the four ordinary tools, and
  `lmx` supplies it by default — `Lemieux.CLI.Options` says why. The
  definition is ordinary host data: the child inherits the parent's model
  (or runs on `:scout_model`) and working tree, gets only the read-only
  `read`, `grep` and `glob`, fixed limits, and no way to broaden itself. `Lemieux.Subagent.Delegate` says why the tool is something a host
  passes rather than something the session assembles, and why it is never
  restored from a transcript — which is also why this extension leaves a
  catalog that already carries a `delegate` alone: on a resume the host may
  have restored one, and two would be two trees of children.

  ## Budgets

  Sized for a child that works for tens of minutes, which is what a capable
  model does with a real brief and a soft deadline. Scouts in one session on
  2026-09-18 spent 200k–340k input tokens in their first two minutes, so the
  fifty cents the child cap used to be would have become the next clock to
  stop them. A loop is bounded by the repeat rules and `Lemieux.Session.Guard`;
  these bound what a child that never loops may spend. The tree's ceiling is
  three children at their full cap — one fan-out — and two of those is the
  most delegated work one session gets.

  A child is bounded in whichever currency its route can enforce. A dollar
  cap on a route that cannot price a request is a stop rather than a loose
  bound — `Lemieux.Session` refuses a request it cannot price against a cap
  — so a priced-in-dollars child on a quota subscription died before its
  first request. Requests are enforceable everywhere; `priced?/2` asks the
  provider which currency this is.

  ## The scout's model

  `:scout_model` runs the scout on a different model from the parent — a
  cheaper, faster one is the ordinary choice, since a scout reads and
  reports and the parent does the reasoning that matters. The parent's
  model is the default, which is what the scout always was.

  ## Workspace agents

  When `Lemieux.Extensions.Workspace` ran first, its discovery sits in the
  harness's `workspace` field with the Claude-compatible subagent
  definitions it found (`.claude/agents/*.md`, a selected plugin's
  `agents/`). Each becomes one more definition on the same `delegate` tool,
  under the same budgets, with its own prompt and description. Every one
  stays certified read-only: the tools it asked for that read (`Read`,
  `Grep`, `Glob`) are granted, and the rest are named in a notice rather
  than granted or silently dropped. A definition that names a model in
  Lemieux's `provider:model` form runs on it and is bounded in requests,
  since whether that model's route can be priced is not known here;
  otherwise it runs on the scout's model under the scout's budget.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Checkpoint.Git
  alias Lemieux.Harness
  alias Lemieux.Provider
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Delegate
  alias Lemieux.Tool
  alias Lemieux.Tools

  @delegate_child_max_cost_usd 3.00
  @delegate_child_max_tokens 8_192
  # The request equivalent of the child cap, for routes that cannot price
  # one. Above the definition's turn default, so the turn limit is what a
  # child meets first and the diagnostic names turns rather than a budget.
  @delegate_child_max_requests 480
  @delegate_tree_max_cost_usd 9.00
  # A spend bound, not a loop bound — the soft deadline's checks stop a
  # runaway long before this does.
  @delegate_tree_max_requests 2_880

  # What a scout, and every workspace agent, may hold: each certifies itself
  # read-only. Searching used to mean walking the tree a directory at a time
  # with `read`, while the parent beside it had `rg` through `bash`; the scout
  # lost to reading directly partly because it was the one with worse tools.
  @read_tools [Tools.Read, Tools.Grep, Tools.Glob]

  @type state :: %{
          model: String.t(),
          priced?: boolean(),
          cwd: Path.t(),
          snapshot: map(),
          options: keyword()
        }

  @doc """
  Options: `:model`, the parent's model (required); `:scout_model`, the model
  the scout runs as, defaulting to `:model`; `:provider`, asked whether it
  can price the scout's model, or `:priced?` to say so outright; `:cwd`, the
  working tree the snapshot names, defaulting to the current directory;
  `:options`, host overrides for `Lemieux.Subagent.Delegate.new/2` —
  scripted child providers in tests, a policy map — merged under the
  budgets, which stay the host's.
  """
  @impl Lemieux.Extension
  @spec init(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  def init(opts) do
    model = scout_model(opts)
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)

    priced? =
      case Keyword.fetch(opts, :priced?) do
        {:ok, priced?} when is_boolean(priced?) -> priced?
        :error -> priced?(Keyword.fetch!(opts, :provider), model)
      end

    {:ok,
     %{
       model: model,
       priced?: priced?,
       cwd: cwd,
       snapshot: workspace_snapshot(cwd),
       options: Keyword.get(opts, :options, [])
     }}
  end

  defp scout_model(opts) do
    case Keyword.get(opts, :scout_model) do
      scout when is_binary(scout) and scout != "" -> scout
      _unset -> Keyword.fetch!(opts, :model)
    end
  end

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, state) do
    {agents, notices} = agent_definitions(harness.workspace, state)

    harness
    |> Harness.update_tools(fn tools ->
      if Enum.any?(tools, &(Tool.name(&1) == "delegate")),
        do: tools,
        else: tools ++ [tool(state, agents)]
    end)
    |> Map.update!(:notices, &(&1 ++ notices))
  end

  @impl Lemieux.Extension
  def describe(%{model: model, priced?: priced?}),
    do: %{"definitions" => ["repository-scout"], "model" => model, "priced" => priced?}

  # The filesystem is read once in init; applying prepared state is pure,
  # including when a screen and a session consume the same preparation.
  defp tool(%{priced?: priced?, snapshot: snapshot, options: options} = state, agents) do
    delegate_opts =
      child_output_bound(priced?)
      |> Keyword.merge(options)
      |> Keyword.merge(
        snapshot: snapshot,
        max_cost_usd: @delegate_tree_max_cost_usd,
        max_requests: @delegate_tree_max_requests
      )

    Delegate.new([repository_scout(state.model, priced?) | agents], delegate_opts)
  end

  # Claude's names for the read-only tools a definition may keep, beside
  # Lemieux's own. Anything else a file asks for is reported, never granted.
  defp agent_definitions(%{agents: agents}, state) when is_list(agents) and agents != [] do
    Enum.map_reduce(agents, [], fn agent, notices ->
      {granted, refused} = agent_tools(agent.tools)
      {agent_definition(agent, granted, state), notices ++ refusal(agent, granted, refused)}
    end)
  end

  defp agent_definitions(_workspace, _state), do: {[], []}

  defp refusal(_agent, _granted, []), do: []

  defp refusal(agent, granted, refused) do
    verb = if length(refused) == 1, do: "is", else: "are"

    [
      "subagent #{agent.id}: #{Enum.join(refused, ", ")} #{verb} not available to read-only " <>
        "subagents; it reads with #{Enum.map_join(granted, ", ", &Tool.name/1)}"
    ]
  end

  defp agent_definition(agent, tools, %{model: scout, priced?: priced?}) do
    {model, budget} =
      case agent.model do
        nil -> {scout, scout_budget(priced?)}
        model -> {model, [max_requests: @delegate_child_max_requests]}
      end

    Definition.new(
      [
        id: agent.id,
        description: agent.description,
        system_prompt: agent.prompt,
        model: model,
        tools: tools,
        metadata: %{"source" => "workspace_agent", "path" => agent.path}
      ] ++ budget
    )
  end

  defp agent_tools(:default), do: {@read_tools, []}

  defp agent_tools(names) when is_list(names) do
    available = Map.new(@read_tools, &{Tool.name(&1), &1})

    {granted, refused} =
      Enum.split_with(names, &Map.has_key?(available, tool_name(&1)))

    granted =
      case granted |> Enum.map(&available[tool_name(&1)]) |> Enum.uniq() do
        [] -> [Tools.Read]
        tools -> tools
      end

    {granted, Enum.uniq(refused)}
  end

  defp tool_name(name), do: name |> String.trim() |> String.downcase()

  @doc """
  Whether this provider can price a request for `model`.

  A `Lemieux.Subagent.Definition` is bounded in dollars and only in dollars
  — `:max_cost_usd` is an enforced key, the group reserves against it, and
  `Lemieux.Subagent.Group` protects it from host override. `Lemieux.Session`
  refuses a request it cannot price against a cap rather than proceeding
  past one it cannot enforce, so a child on an unpriceable route is stopped
  before its first request, every time, and comes back `budget_exhausted`
  with an empty answer. `lmx` supplying such a child by default is worse
  than supplying none.

  Asked of the provider rather than guessed from the model string, because
  the answer is a property of the route: the req_llm provider's cost
  estimate is `nil` for every Ixway-routed request by design, and also for
  any model ReqLLM has no prices for — a local Ollama tag, say.
  """
  @spec priced?(provider :: Provider.t(), model :: String.t()) :: boolean()
  def priced?(provider, model) when is_binary(model) do
    is_number(Provider.estimate_cost(provider, Lemieux.Request.new(model)))
  end

  @doc """
  The scout's definition, bounded in whichever currency `priced?` names.

  Turns, the hard deadline and the check interval stay at the definition's
  defaults: the scout stops when it finishes, when a check finds it stalled,
  or when the hour is up. Six turns was a number chosen here, and a child
  briefed for a five-part investigation spent all six reading; two minutes
  was the next, and it killed three scouts mid-answer.
  """
  @spec repository_scout(model :: String.t(), priced? :: boolean()) :: Definition.t()
  def repository_scout(model, priced?) when is_binary(model) and is_boolean(priced?) do
    Definition.new(
      [
        id: "repository-scout",
        description:
          "Search the working tree (grep, glob) and read it; return source-cited findings",
        system_prompt:
          "Search the repository with grep and glob, then read what matters. Cite exact paths " <>
            "and line numbers, report uncertainty, and say what you searched. Do not propose " <>
            "or make writes.",
        model: model,
        tools: @read_tools
      ] ++ scout_budget(priced?)
    )
  end

  defp scout_budget(true), do: [max_cost_usd: @delegate_child_max_cost_usd]
  defp scout_budget(false), do: [max_requests: @delegate_child_max_requests]

  # The cost gate prices a request's maximum possible output before calling
  # the provider, so on a priced route a model with a 128k output limit
  # exceeds the scout's cap without spending a token. This bound is what
  # keeps the gate from refusing the child outright.
  #
  # It is only ever that. Unpriced there is no gate to satisfy and the bound
  # does harm: `max_tokens` becomes `max_completion_tokens` on a reasoning
  # model, reasoning spends it first, and the child truncates before it
  # answers — measured as 1153 output tokens and four findings becoming 270
  # tokens and no answer.
  defp child_output_bound(true),
    do: [child_options: [params: [max_tokens: @delegate_child_max_tokens]]]

  defp child_output_bound(false), do: []

  defp workspace_snapshot(cwd) do
    %{
      "kind" => "working_tree",
      "version" => 1,
      "cwd" => cwd,
      "revision" => git_revision(cwd)
    }
  end

  # Run on this machine, in a repository the session's commands write: asked
  # with nothing the repository configures run, and read as the object name
  # alone, not the warnings a ref a command wrote adds before it
  # (`Lemieux.Checkpoint.Git.revision/1`).
  defp git_revision(cwd) do
    case Git.revision(cwd) do
      {:ok, revision} -> revision
      :none -> "unversioned"
    end
  end
end

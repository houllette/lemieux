defmodule Lemieux.Extensions.Workspace.Agent do
  @moduledoc """
  A Claude-compatible subagent definition — `.claude/agents/NAME.md`, or an
  `agents/` directory in a selected plugin — as `lmx` reads it.

  The file is Markdown with YAML frontmatter: `name` and `description` are
  required, `tools` and `model` optional, and the body is the subagent's
  system prompt. People who already wrote these for Claude Code get them
  offered as delegation targets with no rewriting, which is the point: the
  scout used to be the only subagent `lmx` had, and a repository's own
  reviewers and researchers sat unread beside it.

  ## What carries over, and what cannot

  A Lemieux subagent is certified read-only (`Lemieux.Subagent.Definition`
  refuses anything else), so this module records the tools a file *asks
  for* and `Lemieux.Extensions.Delegation` keeps only the ones that read. A
  definition asking for `Bash` or `Edit` is still offered, reading, with a
  notice saying what it did not get — refusing it would lose the prompt, and
  granting it would turn a file in a checkout into write authority.

  `model` is honoured when it names a model the way Lemieux does
  (`provider:model`). Claude's aliases (`sonnet`, `opus`, `haiku`) name one
  vendor's current models and mean nothing on another provider, so they,
  `inherit` and an absent `model` all mean the scout's model.

  Everything else in the frontmatter (`color`, `permissionMode`, `hooks`, …)
  is Claude Code's and ignored with a diagnostic where it would change
  behaviour.
  """

  alias Lemieux.Extensions.Workspace.Containment
  alias Lemieux.Extensions.Workspace.Frontmatter

  @max_prompt_bytes 64_000
  @id ~r/\A[a-z][a-z0-9-]{0,63}\z/

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          prompt: String.t(),
          tools: [String.t()] | :default,
          model: String.t() | nil,
          path: Path.t(),
          source: term(),
          diagnostics: [String.t()]
        }

  @enforce_keys [:id, :name, :description, :prompt, :path]
  defstruct [
    :id,
    :name,
    :description,
    :prompt,
    :path,
    tools: :default,
    model: nil,
    source: :workspace,
    diagnostics: []
  ]

  @doc """
  Reads one agent file. `:namespace` prefixes the id (a plugin's name), and
  `:source` records where it came from.
  """
  @spec read(path :: Path.t(), opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def read(path, opts \\ []) when is_binary(path) and is_list(opts) do
    path = Path.expand(path)

    with {:ok, contents} <- read_file(path),
         {:ok, frontmatter, body} <- document(contents, path),
         {:ok, attributes} <- yaml(frontmatter, path),
         {:ok, name} <- text(attributes, "name", path),
         {:ok, description} <- text(attributes, "description", path),
         {:ok, prompt} <- prompt(body, path),
         {:ok, id} <- id(name, Keyword.get(opts, :namespace), path) do
      {tools, tool_diagnostics} = tools(Map.get(attributes, "tools"), path)
      {model, model_diagnostics} = model(Map.get(attributes, "model"), path)

      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         description: description,
         prompt: prompt,
         tools: tools,
         model: model,
         path: path,
         source: Keyword.get(opts, :source, :workspace),
         diagnostics: tool_diagnostics ++ model_diagnostics ++ ignored(attributes, path)
       }}
    end
  end

  @doc """
  Reads every `*.md` directly under each root. A malformed file is a
  diagnostic and does not hide the valid ones beside it; a later root wins
  over an earlier one for the same id, so a repository's definition
  replaces a personal one of the same name.

  `within:` a repository's scope confines the files read to it, as
  `Lemieux.Extensions.Workspace.Skill.discover/2` does: a definition whose
  real path is outside the repository, or in a credential location, is a
  diagnostic instead.
  """
  @spec discover(roots :: [Path.t()], opts :: keyword()) :: {[t()], [String.t()]}
  def discover(roots, opts \\ []) when is_list(roots) and is_list(opts) do
    {paths, left_out} =
      roots
      |> Enum.flat_map(&(&1 |> Path.join("*.md") |> Path.wildcard() |> Enum.sort()))
      |> Containment.split(Keyword.get(opts, :within))

    {agents, diagnostics} =
      paths
      |> Enum.reduce({%{}, left_out}, fn path, {agents, diagnostics} ->
        case read(path, opts) do
          {:ok, agent} -> {Map.put(agents, agent.id, agent), diagnostics ++ agent.diagnostics}
          {:error, reason} -> {agents, diagnostics ++ [reason]}
        end
      end)

    {agents |> Map.values() |> Enum.sort_by(& &1.id), diagnostics}
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "could not read agent #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp document(contents, path) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)(.*)\z/s, contents,
           capture: :all_but_first
         ) do
      [frontmatter, body] -> {:ok, frontmatter, body}
      nil -> {:error, "#{path} needs YAML frontmatter between --- lines"}
    end
  end

  # Claude Code's own agent files are often not strict YAML; see
  # `Lemieux.Extensions.Workspace.Frontmatter`.
  defp yaml(frontmatter, path) do
    case Frontmatter.parse(frontmatter) do
      {:ok, attributes} -> {:ok, attributes}
      {:error, :not_an_object} -> {:error, "#{path} frontmatter must be a YAML object"}
      {:error, {:invalid, detail}} -> {:error, "could not read #{path} frontmatter (#{detail})"}
    end
  end

  defp text(attributes, key, path) do
    case Map.get(attributes, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "#{path} agent needs a #{key}"}
          trimmed -> {:ok, trimmed}
        end

      _missing ->
        {:error, "#{path} agent needs a #{key}"}
    end
  end

  defp prompt(body, path) do
    case String.trim(body) do
      "" ->
        {:error, "#{path} agent needs instructions after its frontmatter"}

      prompt when byte_size(prompt) > @max_prompt_bytes ->
        {:error, "#{path} agent instructions are over #{@max_prompt_bytes} bytes"}

      prompt ->
        {:ok, prompt}
    end
  end

  # A Lemieux definition id is lowercase letters, digits and hyphens, starting
  # with a letter; Claude names are usually already that. A plugin's agents
  # are prefixed with the plugin so two plugins' `reviewer`s stay apart.
  defp id(name, namespace, path) do
    id =
      [namespace, name]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("-")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> then(&if(Regex.match?(~r/\A[a-z]/, &1), do: &1, else: "agent-" <> &1))
      |> String.slice(0, 64)
      |> String.trim_trailing("-")

    cond do
      id == "repository-scout" ->
        {:error, "#{path}: repository-scout is the built-in scout's name; rename this agent"}

      Regex.match?(@id, id) ->
        {:ok, id}

      true ->
        {:error, "#{path}: #{inspect(name)} cannot be made into a subagent id"}
    end
  end

  defp tools(nil, _path), do: {:default, []}

  defp tools(value, path) when is_binary(value) do
    value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> tools(path)
  end

  defp tools(value, path) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: {Enum.reject(value, &(&1 == "")), []},
      else: {:default, ["#{path}: tools must be names; the default read-only tools are used"]}
  end

  defp tools(_value, path),
    do: {:default, ["#{path}: tools must be names; the default read-only tools are used"]}

  defp model(nil, _path), do: {nil, []}
  defp model("inherit", _path), do: {nil, []}

  defp model(value, path) when is_binary(value) do
    if String.contains?(value, ":"),
      do: {value, []},
      else:
        {nil,
         [
           "#{path}: model #{inspect(value)} is a Claude alias; the scout's model is used " <>
             "(write provider:model to choose one)"
         ]}
  end

  defp model(_value, path), do: {nil, ["#{path}: model must be a string; the scout's is used"]}

  defp ignored(attributes, path) do
    for key <- ~w(permissionMode hooks mcpServers), Map.has_key?(attributes, key) do
      "#{path}: #{key} is not applied to lmx subagents"
    end
  end
end

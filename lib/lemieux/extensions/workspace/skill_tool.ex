defmodule Lemieux.Extensions.Workspace.SkillTool do
  @moduledoc """
  The workspace extension's allowlisted Agent Skills loader.

  The ordinary `read` tool is deliberately confined to the session working
  directory. Personal skills and revision-cached plugin skills live outside
  that boundary, so advertising their paths and asking the model to read them
  produced a feature that only worked for repository-local skills. This
  configured tool exposes only the skill files the host discovered and
  validated; a model-supplied path is never accepted.

  It is a host tool rather than a member of `Lemieux.Tools.default/0` because
  skill discovery belongs to `Lemieux.Extensions.Workspace`, not to agent-loop
  policy imposed on library embedders, and because the paths it holds are
  valid only in the runtime that discovered them.

  ## Long skills come in parts

  A result larger than the session's tool-output cap is cut from the middle
  by the executor, which for instructions means losing the steps in the
  middle without anybody noticing. So a skill longer than one result is
  split on line boundaries into parts that each fit the cap the session
  actually has (`:tool_output_bytes` in the tool context, bounded by this
  tool's own), and every part but the last ends by saying which part to ask
  for next. A skill that fits is returned whole, as before.

  ## Files beside a skill

  `"file"` loads one of the files in a skill's directory instead of its
  instructions — Omarchy's skill says to read `hyprland.md` before touching
  Hyprland's configuration, and nothing else the model has can reach
  `/usr/share/omarchy`. The path is relative to the skill's real directory,
  as the loaded instructions list them, and
  `Lemieux.Extensions.Workspace.Skill.file/3` decides what may be read. A
  file is paged like a body; `"arguments"` apply to a body only, since a
  reference file is not a template.
  """

  @behaviour Lemieux.Tool.Configured

  alias Lemieux.Extensions.Workspace.Skill

  @max_output_bytes 60_000
  # Room for the continuation notice and the executor's own framing.
  @page_overhead 1_000

  @type t :: %__MODULE__{
          skills: %{required(String.t()) => Skill.t()},
          home: Path.t() | nil
        }

  @enforce_keys [:skills]
  defstruct [:skills, :home]

  @doc """
  Builds a loader from the model-invocable subset of discovered skills.

  `:home` is the home directory whose credential locations a skill's files
  may never come from, the user's by default.
  """
  @spec new(skills :: [Skill.t()], opts :: keyword()) :: t()
  def new(skills, opts \\ []) when is_list(skills) and is_list(opts) do
    available =
      skills
      |> Enum.filter(& &1.model_invocable?)
      |> Map.new(&{Skill.qualified_name(&1), &1})

    %__MODULE__{skills: available, home: Keyword.get(opts, :home)}
  end

  @impl Lemieux.Tool.Configured
  def name(%__MODULE__{}), do: "skill"

  @impl Lemieux.Tool.Configured
  def description(%__MODULE__{}) do
    "Load the complete instructions for one available Agent Skill. " <>
      "Use this when the task matches a skill advertised in the system prompt. " <>
      "When its instructions refer to a file in the skill's directory, load that file " <>
      "with the same name and \"file\" set to its path relative to the directory."
  end

  @impl Lemieux.Tool.Configured
  def schema(%__MODULE__{skills: skills}) do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "enum" => skills |> Map.keys() |> Enum.sort(),
          "description" => "Qualified skill name from the available skills catalog."
        },
        "arguments" => %{
          "type" => "string",
          "description" => "Optional arguments to substitute into the skill instructions."
        },
        "file" => %{
          "type" => "string",
          "description" =>
            "Optional. A file in the skill's directory to load instead of its " <>
              "instructions, relative to that directory, as the loaded skill lists " <>
              "them (\"reference.md\", \"references/api.md\")."
        },
        "part" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" => "For a long skill or file, which part to load. Defaults to 1."
        }
      },
      "required" => ["name"],
      "additionalProperties" => false
    }
  end

  @impl Lemieux.Tool.Configured
  def run(%__MODULE__{} = tool, %{"name" => name} = arguments, context)
      when is_binary(name) do
    with {:ok, skill} <- fetch(tool, name),
         {:ok, text, label} <- content(tool, skill, arguments) do
      text
      |> pages(page_bytes(context))
      |> part(Map.get(arguments, "part", 1), label)
    end
  end

  def run(%__MODULE__{}, _arguments, _context), do: {:error, "skill needs a name"}

  # An empty "file" is the body: models that fill every optional field send
  # one when they mean none.
  defp content(tool, skill, %{"file" => file} = arguments) when file in [nil, ""],
    do: content(tool, skill, Map.delete(arguments, "file"))

  defp content(tool, skill, %{"file" => file}) when is_binary(file) do
    name = Skill.qualified_name(skill)
    opts = if tool.home, do: [home: tool.home], else: []

    with {:ok, text} <- Skill.file(skill, file, opts) do
      {:ok, "Skill: #{name}\nFile: #{file} (in #{skill.root})\n\n#{text}",
       {name, ~s( file #{file}), ~s( and the same "file")}}
    end
  end

  defp content(_tool, _skill, %{"file" => _other}),
    do: {:error, "file is a path relative to the skill directory, as a string"}

  defp content(_tool, skill, arguments) do
    with {:ok, rendered} <- Skill.render(skill, Map.get(arguments, "arguments", "")) do
      {:ok, rendered, {Skill.qualified_name(skill), "", ""}}
    end
  end

  defp fetch(tool, name) do
    case Map.fetch(tool.skills, name) do
      {:ok, skill} -> {:ok, skill}
      :error -> {:error, "unknown or non-model-invocable skill #{inspect(name)}"}
    end
  end

  defp page_bytes(context) do
    host = Map.get(context, :tool_output_bytes, @max_output_bytes)
    max(min(host, @max_output_bytes) - @page_overhead, @page_overhead)
  end

  # `label` is the skill's name, what follows it for a file (" file x.md"),
  # and what else the next call must repeat (the same "file").
  defp part([whole], 1, _label), do: {:ok, whole}

  defp part(pages, number, {name, what, repeat}) when is_integer(number) and number >= 1 do
    total = length(pages)

    case Enum.at(pages, number - 1) do
      nil ->
        {:error, "skill #{name}#{what} has #{total} parts; ask for a part from 1 to #{total}"}

      page when number == total ->
        {:ok, page <> "\n\n[Skill #{name}#{what}: part #{total} of #{total}, the end.]"}

      page ->
        {:ok,
         page <>
           "\n\n[Skill #{name}#{what}: part #{number} of #{total}. Call skill again with " <>
           "\"part\": #{number + 1}#{repeat} for the rest before acting on it.]"}
    end
  end

  defp part(_pages, _number, {name, what, _repeat}),
    do: {:error, "skill #{name}#{what}: part must be 1 or more"}

  # Whole lines into pages of at most `bytes`; a single line longer than a
  # page is split where it must be, on a character boundary.
  defp pages(text, bytes) when byte_size(text) <= bytes, do: [text]

  defp pages(text, bytes) do
    text
    |> String.split("\n")
    |> Enum.flat_map(&split_long(&1, bytes))
    |> Enum.chunk_while(nil, &add_line(&1, &2, bytes), fn
      nil -> {:cont, nil}
      page -> {:cont, page, nil}
    end)
  end

  defp add_line(line, nil, _bytes), do: {:cont, line}

  defp add_line(line, page, bytes) do
    candidate = page <> "\n" <> line
    if byte_size(candidate) <= bytes, do: {:cont, candidate}, else: {:cont, page, line}
  end

  defp split_long(line, bytes) when byte_size(line) <= bytes, do: [line]

  defp split_long(line, bytes) do
    {head, rest} = String.split_at(line, div(bytes, 4))
    [head | split_long(rest, bytes)]
  end

  @impl Lemieux.Tool.Configured
  def parallel_safe?(%__MODULE__{}), do: true

  @impl Lemieux.Tool.Configured
  def read_only?(%__MODULE__{}), do: true

  @impl Lemieux.Tool.Configured
  def metadata(%__MODULE__{}) do
    %{
      effects: %{
        class: "read",
        resource_types: ["agent_skill"],
        idempotent: true,
        retryable: true
      },
      policy: %{approval: "never"},
      runtime: %{concurrency: %{class: "parallel"}, max_output_bytes: @max_output_bytes}
    }
  end
end

defmodule Lemieux.CLI.Runtime.Assembly do
  @moduledoc false

  alias Lemieux.CLI.Startup
  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tools

  # This is CLI reconstruction data, not executable configuration. Equipment
  # (profiles, interactive tools, network tools and delegation) is resolved by
  # the current host. Workspace/user transformations then run once over that
  # equipment. Recording only the final module catalog loses wrapped tools;
  # replaying transforms over their final output duplicates added tools.
  @spec seed(recorded :: map(), extensions :: [Lemieux.Extension.spec()]) ::
          {:ok, [Tool.t()] | nil} | {:error, String.t()}
  def seed(
        %{"harness_assembly" => %{"version" => 1, "tools" => tools, "required" => required}},
        extensions
      )
      when is_list(tools) and is_list(required) do
    selected = Enum.map(extensions, &name/1)
    missing = required -- selected

    cond do
      not Enum.all?(required, &is_binary/1) ->
        {:error, "invalid harness assembly record; supply an explicit :tools replacement catalog"}

      missing == [] ->
        modules(tools)

      true ->
        {:error,
         "resuming needs #{Enum.join(missing, ", ")} to reconstruct its tool policy; supply the extension again or an explicit :tools replacement catalog"}
    end
  end

  def seed(%{"harness_assembly" => _}, _extensions),
    do:
      {:error,
       "this session's harness assembly record is unsupported; supply an explicit :tools replacement catalog"}

  def seed(recorded, _extensions) do
    case recorded["tools"] do
      nil -> {:ok, nil}
      tools -> modules(tools)
    end
  end

  defp modules(names) when is_list(names) do
    {:ok, Enum.map(names, &module/1)}
  rescue
    error in [ArgumentError, FunctionClauseError] ->
      {:error,
       "recorded tool modules are unavailable or invalid (#{Exception.message(error)}); supply an explicit :tools replacement catalog"}
  end

  defp modules(_),
    do: {:error, "recorded tools must be a list; supply an explicit :tools replacement catalog"}

  defp module(name) when is_binary(name), do: String.to_existing_atom(name)
  defp module(module) when is_atom(module), do: module

  @spec apply(harness :: Harness.t(), extensions :: [Lemieux.Extension.spec()], opts :: keyword()) ::
          {:ok, Harness.t()} | {:error, term()}
  def apply(harness, extensions, opts \\ []) do
    base = harness.tools || Tools.default()

    extensions
    |> Enum.reduce_while({:ok, harness, []}, fn extension, {:ok, current, required} ->
      before = current.tools || Tools.default()

      case Startup.assemble_extension(current, extension, opts) do
        {:ok, updated} ->
          required = require_transformation(required, extension, before, updated)

          {:cont, {:ok, updated, required}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, updated, required} -> {:ok, record(updated, harness, base, extensions, required)}
      error -> error
    end
  end

  # A transformation is required on resume because a policy may depend on it:
  # an extension that removed `bash` must not be silently absent when the
  # session comes back with `bash` in its recorded catalog. Recording what the
  # file tools change is not a policy. Checkpoints wraps the tools it finds
  # and changes nothing they do, so a session resumed without it — after
  # `disabled_extensions`, or under `--config none` — simply is not recorded,
  # rather than refusing to resume.
  @observers ["Lemieux.Extensions.Checkpoints"]

  defp require_transformation(required, extension, before, updated) do
    name = name(extension)

    if name not in @observers and changes_existing?(before, updated.tools || Tools.default()),
      do: required ++ [name],
      else: required
  end

  defp changes_existing?(before, after_tools),
    do:
      Enum.any?(before, fn tool ->
        Enum.find(after_tools, &(Tool.name(&1) == Tool.name(tool))) != tool
      end)

  defp record(harness, original, base, extensions, required) do
    if base == (harness.tools || Tools.default()) and original.system == harness.system and
         is_nil(harness.max_turns) and is_nil(harness.max_requests) and
         is_nil(harness.max_cost_usd) do
      harness
    else
      recipe = %{
        "version" => 1,
        "system" =>
          if(original.system == :default, do: Lemieux.Prompt.default(), else: original.system),
        "tools" => base |> Enum.filter(&is_atom/1) |> Enum.map(&Atom.to_string/1),
        "extensions" => Enum.map(extensions, &name/1),
        "required" => Enum.uniq(required)
      }

      Harness.update_harness_context(harness, &Map.put(&1, "assembly", recipe))
    end
  end

  defp name({module, _opts}), do: inspect(module)
  defp name(module), do: inspect(module)
end

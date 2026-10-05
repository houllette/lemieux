defmodule Lemieux.Extensions.ApplyPatch do
  @moduledoc """
  Puts `apply_patch` in `edit`'s place for the models trained on it.

  GPT-5-family models were trained to edit files with the patch format
  `Lemieux.Tools.ApplyPatch` reads, and use it more reliably than an
  exact-string `edit` in a dialect they were not trained on. Other models
  keep `edit`: the patch format costs them more than it saves.

  The model comes from the options, because the catalog is fixed when the
  session starts; a session that switches model later keeps the tool it
  started with. A catalog without `edit` is left alone, since swapping would
  grant a write tool a profile had deliberately withheld.

  Options:

    * `:model` — the session's model spec, for example `"openai:gpt-5"`.
    * `:models` — patterns naming the models that get `apply_patch`, matched
      against the model name with any provider prefix and vendor path
      removed; `*` matches anything. Defaults to the GPT-5 family.
    * `:mode` — `:replace` (the default) swaps `edit` out; `:add` offers both.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tools.ApplyPatch

  @default_models ["gpt-5", "gpt-5.*", "gpt-5-*"]

  @impl Lemieux.Extension
  def init(opts) do
    mode = Keyword.get(opts, :mode, :replace)
    models = Keyword.get(opts, :models, @default_models)

    cond do
      mode not in [:replace, :add] ->
        {:error, ":mode must be :replace or :add; got #{inspect(mode)}"}

      not (is_list(models) and Enum.all?(models, &is_binary/1)) ->
        {:error, ":models must be a list of strings"}

      true ->
        model = Keyword.get(opts, :model)
        {:ok, %{model: model, models: models, mode: mode, active?: matches?(model, models)}}
    end
  end

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, %{active?: false}), do: harness

  def apply(%Harness{} = harness, %{mode: mode}) do
    Harness.update_tools(harness, &swap(&1, mode))
  end

  @impl Lemieux.Extension
  def describe(state) do
    %{"model" => state.model, "active" => state.active?, "mode" => Atom.to_string(state.mode)}
  end

  @doc """
  Whether `model` belongs to the family `patterns` names.

  The name compared is the model's own: `"openai:gpt-5.1"`,
  `"ixway:gpt-5.6-luna"` and `"openrouter:openai/gpt-5-mini"` are all
  `gpt-5…` models, whoever serves them.
  """
  @spec matches?(model :: String.t() | nil, patterns :: [String.t()]) :: boolean()
  def matches?(model, patterns) when is_binary(model) do
    name =
      model
      |> String.split(":")
      |> List.last()
      |> String.split("/")
      |> List.last()
      |> String.downcase()

    Enum.any?(patterns, &wildcard?(&1, name))
  end

  def matches?(_model, _patterns), do: false

  defp wildcard?(pattern, name) do
    source =
      pattern
      |> String.downcase()
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.match?(Regex.compile!("\\A" <> source <> "\\z"), name)
  end

  defp swap(tools, mode) do
    names = Enum.map(tools, &Tool.name/1)

    cond do
      "apply_patch" in names -> tools
      "edit" not in names -> tools
      mode == :add -> insert_after_edit(tools)
      true -> Enum.map(tools, &if(Tool.name(&1) == "edit", do: ApplyPatch, else: &1))
    end
  end

  defp insert_after_edit(tools) do
    {before, [edit | rest]} = Enum.split_while(tools, &(Tool.name(&1) != "edit"))
    before ++ [edit, ApplyPatch | rest]
  end
end

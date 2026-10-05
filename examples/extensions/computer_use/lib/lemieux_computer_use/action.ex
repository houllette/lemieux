defmodule LemieuxComputerUse.Action do
  @moduledoc "An internal governed action: each input crosses the current host's tool hooks."
  @behaviour Lemieux.Tool.Configured
  defstruct [:driver, :session, :page, :action, :text, :opts]

  @impl true
  def name(_), do: "computer_use_action"
  @impl true
  def description(_), do: "Execute one observed browser action under host policy"
  @impl true
  def schema(_), do: %{"type" => "object", "properties" => %{}}
  @impl true
  def run(tool, args, _context) do
    expected = arguments(tool.page, tool.action, tool.text)
    # A rewrite must not detach the hook's audited arguments from the observed
    # action actually executed. Re-observe/reclassify instead of guessing.
    with true <- args == expected,
         :ok <- navigation(tool.action, tool.opts) do
      execute(tool)
    else
      false -> {:error, "Rewritten browser actions require a new observation"}
      {:error, _} = error -> error
    end
  end

  @spec arguments(page :: map(), action :: map(), text :: String.t() | nil) :: map()
  def arguments(page, action, text),
    do: %{
      "url" => page["url"],
      "operation" => action["operation"],
      "target" => action["id"],
      "label" => action["label"],
      "text" => text
    }

  defp navigation(action, opts) do
    Enum.reduce_while([action["href"], action["form_action"]], :ok, fn
      nil, :ok ->
        {:cont, :ok}

      url, :ok ->
        case LemieuxComputerUse.Policy.check(url, opts) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
    end)
  end

  defp execute(%{action: %{"operation" => "WAIT"}}) do
    receive do
    after
      100 -> {:ok, "waited"}
    end
  end

  defp execute(tool) do
    case tool.driver.act(tool.session, tool.page, tool.action, tool.text) do
      :ok ->
        {:ok, "executed"}

      {:error, :stale} ->
        {:error,
         Lemieux.Tool.Result.new("Observation became stale; no input attempted",
           structured_content: %{"stale" => true}
         )}

      {:error, _} ->
        {:error, "Browser action outcome is uncertain; stopped without retry"}
    end
  end
end

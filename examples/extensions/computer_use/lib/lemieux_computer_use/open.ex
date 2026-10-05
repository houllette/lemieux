defmodule LemieuxComputerUse.Open do
  @moduledoc "Governed initial navigation; the opening worker retains browser ownership."
  @behaviour Lemieux.Tool.Configured
  defstruct [:url, :driver, :opts, :reply_ref]

  @impl true
  def name(_), do: "computer_use_open"
  @impl true
  def description(_), do: "Open a fresh browser session at the permitted URL"
  @impl true
  def schema(_), do: %{"type" => "object", "properties" => %{"url" => %{"type" => "string"}}}
  @impl true
  def run(tool, args, _context) do
    with true <- args == %{"url" => tool.url},
         :ok <- LemieuxComputerUse.Policy.check(tool.url, tool.opts),
         {:ok, session} <- tool.driver.open(tool.url, tool.opts) do
      # Tools.run is synchronous in this worker. Keep the live handle in its
      # private mailbox instead of serializing it into tool/transcript evidence.
      send(self(), {tool.reply_ref, session})
      {:ok, "Browser session opened"}
    else
      _ -> {:error, "Initial browser navigation refused or failed"}
    end
  end
end

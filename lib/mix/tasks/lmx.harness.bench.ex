defmodule Mix.Tasks.Lmx.Harness.Bench do
  @moduledoc """
  Runs reproducible preparation samples and prints JSON. No extensions are
  loaded from personal config and no model calls are made. Run on the same
  host/toolchain when comparing results; these measurements are observations,
  not universal latency thresholds. Options: `--iterations N` (default 30).
  """
  use Mix.Task
  alias Lemieux.Extensions
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Tool

  @impl Mix.Task
  def run(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: [iterations: :integer])
    count = Keyword.get(opts, :iterations, 30)
    if count not in 1..1_000, do: Mix.raise("iterations must be between 1 and 1000")
    Mix.Task.run("app.start")
    provider = Scripted.new([])

    reports =
      for {name, options} <- [
            {"core", [delegate: false]},
            {"coding", []},
            {"interactive", [interactive: true]}
          ],
          into: %{} do
        recipe = Extensions.coding("test:model", provider, options) |> Keyword.values()
        {:ok, warm} = Harness.assemble(Harness.new(), recipe)
        before = :erlang.system_info(:process_count)

        samples = samples(recipe, count)
        tools = warm.tools || Lemieux.Tools.default()

        {name,
         %{
           "median_us" => Enum.at(samples, div(count, 2)),
           "p95_us" => Enum.at(samples, max(ceil(count * 0.95) - 1, 0)),
           "process_delta" => :erlang.system_info(:process_count) - before,
           "catalog_count" => length(tools),
           "schema_bytes" => tools |> Enum.map(&Tool.schema/1) |> JSON.encode!() |> byte_size(),
           "prepared_bytes" => :erlang.external_size(warm)
         }}
      end

    [] = Scripted.requests(provider)

    IO.puts(
      JSON.encode!(%{
        "iterations" => count,
        "elixir" => System.version(),
        "otp" => System.otp_release(),
        "measurements" => reports
      })
    )
  end

  defp samples(recipe, count) do
    Enum.map(1..count, fn _ ->
      {us, {:ok, _}} = :timer.tc(fn -> Harness.assemble(Harness.new(), recipe) end)
      us
    end)
    |> Enum.sort()
  end
end

defmodule LemieuxPackageConsumer.Messages do
  @moduledoc "A one-sentence customization; every other sentence is inherited."
  @behaviour Lemieux.Messages
  @impl true
  def tools_changed(_names), do: "The host updated your available operations."
end

defmodule LemieuxPackageConsumer.Compaction do
  @moduledoc "A full strategy retaining the shipped cut/replay contract with tailored instructions."
  @behaviour Lemieux.Compaction
  @impl true
  defdelegate plan(state, entries, opts), to: Lemieux.Compaction
  @impl true
  defdelegate applied(state, entries, opts), to: Lemieux.Compaction
  @impl true
  defdelegate conversation?(state, entries), to: Lemieux.Compaction
  @impl true
  defdelegate summary(state, entries), to: Lemieux.Compaction
  @impl true
  defdelegate sections(state, summary), to: Lemieux.Compaction
  @impl true
  defdelegate with_summary(state, system, summary), to: Lemieux.Compaction
  @impl true
  def instructions(state, previous, opts),
    do:
      Lemieux.Compaction.instructions(state, previous, opts) <>
        "\nPreserve unanswered analysis questions."
end

defmodule LemieuxPackageConsumer.Environment do
  @moduledoc "A restricted host provides no filesystem or command authority."
  @behaviour Lemieux.Environment
  @impl true
  def read_file(_state, _cwd, _path), do: {:error, :not_found}
  @impl true
  def list_dir(_state, _cwd, _path), do: {:error, :not_found}
  @impl true
  def write_file(_state, _cwd, _path, _contents), do: {:error, :forbidden}
  @impl true
  def run(_state, _command, _opts), do: {:error, :forbidden}
end

defmodule LemieuxPackageConsumer.Query do
  @moduledoc "A deterministic stand-in for an application-owned scoped query."
  @behaviour Lemieux.Tool
  @impl true
  def name, do: "scoped_query"
  @impl true
  def description, do: "Read the fixture's scoped row count."
  @impl true
  def schema, do: %{"type" => "object", "properties" => %{}}
  @impl true
  def run(_args, _context), do: {:ok, "rows: 2"}
end

defmodule LemieuxPackageConsumer.Audit do
  @moduledoc "Wrapping a host tool preserves its identity and adds a result marker."
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]
  alias Lemieux.Tool.Override
  alias LemieuxPackageConsumer.Query

  @impl true
  def apply(harness, opts) do
    wrapped = Override.new!(Query, digest: "consumer-audit-v1", after: &annotate/3)

    %{
      harness
      | host_tools: [wrapped],
        messages: LemieuxPackageConsumer.Messages,
        compaction: LemieuxPackageConsumer.Compaction,
        max_requests: Keyword.get(opts, :requests, 99)
    }
  end

  defp annotate({:ok, output}, _args, _context), do: {:ok, output <> " [audited]"}
  defp annotate(other, _args, _context), do: other
end

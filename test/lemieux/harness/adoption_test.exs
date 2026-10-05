defmodule Lemieux.Harness.AdoptionTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defmodule Opinion do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]
    @impl true
    def apply(h, _), do: %{h | max_requests: 99, system: "PRIVATE PROMPT"}
    @impl true
    def describe(_), do: %{"private" => "DUMMY PRIVATE OPTION"}
  end

  defmodule InvalidDescription do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]
    @impl true
    def apply(h, _), do: h
    @impl true
    def describe(_), do: %{"callback" => fn -> "private" end}
  end

  test "explanations show sources and final host limits without copying private data" do
    {:ok, h} = Harness.assemble(Harness.new(), [Opinion])
    report = Harness.explain(h, max_requests: 1, disabled_tools: ["bash"])
    assert report["settings"]["max_requests"] == 1
    assert report["host_overrides"] == ["disabled_tools", "max_requests"]
    assert [%{"changes" => ["system", "max_requests"]}] = report["extensions"]
    assert %{"enabled" => false} = Enum.find(report["tools"], &(&1["name"] == "bash"))
    refute JSON.encode!(report) =~ "PRIVATE"
    assert Map.has_key?(Harness.diff(Harness.explain(h), report), "settings")
    assert Harness.diff(report, report) == %{}
  end

  test "unserializable descriptions fail during assembly with an author diagnostic" do
    assert_raise ArgumentError, ~r/InvalidDescription.describe.*JSON-compatible/, fn ->
      Harness.assemble(Harness.new(), [InvalidDescription])
    end
  end

  test "incomplete strategies fail before recording a session", %{tmp_dir: tmp_dir} do
    supervisor = :"adoption_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})
    store = JSONL.new(tmp_dir)
    provider = Scripted.new([])

    for field <- [:guard, :compaction] do
      assert {:error, {%ArgumentError{message: message}, _}} =
               Lemieux.start_session(
                 [supervisor: supervisor, provider: provider, store: store, model: "test:model"] ++
                   [{field, String}]
               )

      assert message =~ ":#{field} String is missing callbacks"
    end

    assert Scripted.requests(provider) == []
    assert {:ok, []} = Lemieux.Store.list_sessions(store)
  end

  test "CLI recovery bypasses personal extensions but retains host policy", %{tmp_dir: tmp_dir} do
    config = Path.join(tmp_dir, "config.json")
    File.write!(config, ~s({"version":1,"extensions":["missing"]}))
    provider = Scripted.new([])

    output =
      capture_io(fn ->
        assert :ok =
                 Lemieux.CLI.run(
                   ["explain", "--config", config, "--no-user-extensions", "--no-delegate"],
                   provider: provider,
                   store: JSONL.new(tmp_dir),
                   extensions: [Opinion],
                   max_requests: 1
                 )
      end)

    report = JSON.decode!(output)
    assert report["settings"]["max_requests"] == 1
    # The host's own extension still applies, last; nothing the person
    # selected was loaded, only what lmx itself ships.
    modules = Enum.map(report["extensions"], & &1["module"])
    assert List.last(modules) == "Lemieux.Harness.AdoptionTest.Opinion"
    assert modules |> Enum.drop(-1) |> Enum.all?(&String.starts_with?(&1, "Lemieux.Extensions."))
    assert Scripted.requests(provider) == []
    refute output =~ "PRIVATE"
  end
end

defmodule LemieuxBuilderBench.ConfirmationCases do
  @moduledoc false
  # Fresh clusters for the independent confirmation of the builder recipe
  # (roadmap V1). Nothing here overlaps the 2026-09-14 tuning inputs: the audit
  # sources are the subagent admission and budget modules rather than the
  # extension workflow, the seeded defect drops a term from a bound check rather
  # than swapping min for max, and the project cases start from deterministic
  # scaffolds instead of hand-written stubs. Once dispatched, every case here is
  # exposed development material and cannot become hidden confirmation evidence.

  alias Lemieux.Learning.Builder.Scaffold

  @audit_sources ~w(lib/lemieux/subagent/admission.ex lib/lemieux/subagent/money.ex lib/lemieux/benchmark/budget.ex)
  @seeded_file "lib/lemieux/subagent/admission.ex"
  # The request ceiling check must count live reservations. Dropping `reserved`
  # admits a second fan-out while the first still holds its requests: with a
  # ceiling of 10 and one active child holding 8, a new child asking for 8 is
  # admitted (0 + 8 <= 10) and the tree holds 16. The dollar check three lines
  # below keeps the correct form, so a reader who traces one can see the other.
  @seeded_original "    incoming = Enum.sum(Enum.map(children, &reserved_requests/1))\n\n    if spent + reserved + incoming <= ceiling,\n"
  @seeded_defect "    incoming = Enum.sum(Enum.map(children, &reserved_requests/1))\n\n    if spent + incoming <= ceiling,\n"

  @clusters [
    {"audit_admission_clean", "budget_audit"},
    {"audit_admission_seeded", "budget_audit"},
    {"tool_count_lines", "native_tool"},
    {"tool_word_count", "native_tool"},
    {"dep_add", "dependency"},
    {"dep_manifest", "dependency"},
    {"models_reconcile", "maintenance"},
    {"scaffold_quota", "maintenance"}
  ]

  @shortlist [
    %{"model" => "zai_coding_plan:glm-4.7", "efforts" => ["default"]},
    %{"model" => "zai_coding_plan:glm-5.3", "efforts" => ["default"]}
  ]

  @authorized "\nUse only this workspace; quota usage for this authoring task is authorized.\n"

  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@clusters, &elem(&1, 0))

  @spec cluster(id :: String.t()) :: String.t()
  def cluster(id), do: @clusters |> List.keyfind!(id, 0) |> elem(1)

  @doc "The explicit shortlist the maintenance brief dictates; it must be selectable before dispatch."
  @spec shortlist() :: [map()]
  def shortlist, do: @shortlist

  @spec prepare(root :: Path.t(), repository :: Path.t()) :: [String.t()]
  def prepare(root, repository) do
    case File.mkdir(root) do
      :ok ->
        ids = create(root, repository)
        {:ok, _} = Lemieux.Learning.Extension.Tree.seal(root, "inputs.json", %{"case_ids" => ids})
        ids

      {:error, :eexist} ->
        {:ok, receipt} = Lemieux.Learning.Extension.Tree.read(Path.join(root, "inputs.json"))
        {:ok, verified} = Lemieux.Learning.Extension.Tree.verify(root, "inputs.json", receipt["sha256"])
        verified["case_ids"]
    end
  end

  @spec create(root :: Path.t(), repository :: Path.t()) :: [String.t()]
  def create(root, repository) do
    audits(root, repository)
    native_tools(root)
    dependencies(root)
    maintenance(root)
    ids()
  end

  defp audits(root, repository) do
    for id <- ~w(audit_admission_clean audit_admission_seeded) do
      cwd = Path.join(root, id)

      for file <- @audit_sources do
        target = Path.join(cwd, file)
        File.mkdir_p!(Path.dirname(target))
        File.cp!(Path.join(repository, file), target)
      end

      if id == "audit_admission_seeded" do
        target = Path.join(cwd, @seeded_file)
        original = File.read!(target)
        [_before, _after] = String.split(original, @seeded_original)
        File.write!(target, String.replace(original, @seeded_original, @seeded_defect))
      end

      File.write!(Path.join(cwd, "brief.txt"), """
      Audit these source copies of Lemieux's subagent admission and budget
      accounting for concrete reservation, release and bound defects. Sources may
      be correct; do not invent a bug. Read the relevant sources. Do not change
      them, scaffold, run Mix/Elixir, launch model processes, or read outside this
      workspace. Write review.json: {"findings":[{"file":"relative source
      path","quote":"exact defective source expression","description":"why it
      violates a contract"}]}. Use an empty findings array if there is no
      demonstrated defect. Then write BUILDING.md with a concise account of
      evidence and remaining validation. Charging unmeasured usage at its full
      reservation is documented policy, not a defect. Finish once those two
      artifacts are saved. A source review is not live confirmation.
      """)
    end
  end

  defp native_tools(root) do
    for id <- ~w(tool_count_lines tool_word_count) do
      cwd = Path.join(root, id)
      scaffold!(cwd, "line_audit", "Audit one text file and report its line statistics.")

      if id == "tool_word_count" do
        tool = "lib/line_audit/tools/word_count.ex"
        File.mkdir_p!(Path.join(cwd, Path.dirname(tool)))
        File.write!(Path.join(cwd, tool), word_count_source())
        add_to_manifest!(cwd, [tool])
      end

      brief =
        if id == "tool_count_lines" do
          """
          This workspace is an existing scaffolded Lemieux extension (LineAudit).
          Add a native tool. Implement a Lemieux.Tool module under lib/ whose tool
          name is count_lines: it takes {"path": string} relative to the session
          working directory (context.cwd), reads that file, and returns only the
          decimal number of newline-terminated lines, so "a\\nb\\nc\\n" is 3 and
          "a\\nb" is 1. Declare it read-only and parallel-safe. Register the module
          in tool_registry/0 in lib/line_audit.ex, add "count_lines" to the tools
          list in priv/profile.json without changing any other profile setting,
          list the new source file in lemieux-extension.json, and record the tool,
          its contract and the pending validation in BUILDING.md. Preserve
          README.md, mix.exs, .formatter.exs and everything under bench/ byte for
          byte. Do not run Mix, compile, fetch dependencies, benchmark or launch
          model processes; the host compiles and checks the tool offline afterwards.
          """
        else
          """
          This workspace is an existing scaffolded Lemieux extension (LineAudit).
          The developer already implemented a native tool module at
          lib/line_audit/tools/word_count.ex (tool name word_count) but never
          wired it in. Register that module in tool_registry/0 in
          lib/line_audit.ex, add "word_count" to the tools list in
          priv/profile.json without changing any other profile setting, and
          record the decision and the pending validation in BUILDING.md. Do not
          modify the tool module, README.md, mix.exs, .formatter.exs,
          lemieux-extension.json or anything under bench/. Do not run Mix,
          compile, fetch dependencies, benchmark or launch model processes; the
          host compiles and checks the registry offline afterwards.
          """
        end

      File.write!(Path.join(cwd, "brief.txt"), brief <> @authorized)
    end
  end

  defp dependencies(root) do
    for id <- ~w(dep_add dep_manifest) do
      cwd = Path.join(root, id)
      ext = Path.join(cwd, "line_stats")
      scaffold!(ext, "line_stats", "Summarize one text file's line statistics.")
      vendor_text_stats!(Path.join(cwd, "vendor/text_stats"))

      if id == "dep_manifest" do
        mix = Path.join(ext, "mix.exs")
        original = File.read!(mix)
        # Anchored on the end of the scaffold's dependency list rather than
        # on a version it names: a pinned `~> 0.13` stopped matching when the
        # scaffold moved to `~> 0.16`, and preparation crashed here.
        anchor = "optional: true}]]"
        [before, _after] = String.split(original, anchor)
        [indent] = Regex.run(~r/[ ]*(?=\S[^\n]*\z)/, before)

        File.write!(
          mix,
          String.replace(
            original,
            anchor,
            "optional: true},\n" <> indent <> "{:text_stats, path: \"../vendor/text_stats\"}]]"
          )
        )

        File.write!(Path.join(ext, "mix.lock"), "%{}\n")
        File.mkdir_p!(Path.join(ext, "lib/line_stats"))

        File.write!(Path.join(ext, "lib/line_stats/stats.ex"), """
        defmodule LineStats.Stats do
          @moduledoc "Deterministic summary of one text, built on the vendored TextStats."

          @spec summarize(text :: String.t()) :: %{lines: non_neg_integer()}
          def summarize(text) when is_binary(text), do: %{lines: TextStats.line_count(text)}
        end
        """)

        File.mkdir_p!(Path.join(ext, "test"))
        File.write!(Path.join(ext, "test/test_helper.exs"), "ExUnit.start()\n")

        File.write!(Path.join(ext, "test/line_stats_test.exs"), """
        defmodule LineStatsTest do
          use ExUnit.Case, async: true

          test "counts newline-terminated lines" do
            assert LineStats.Stats.summarize("a\\nb\\n") == %{lines: 2}
          end
        end
        """)
      end

      brief =
        if id == "dep_add" do
          """
          The extension in ./line_stats is a scaffolded Lemieux extension
          (LineStats). A local library already exists on disk at
          ./vendor/text_stats (Mix application :text_stats). Add it to
          line_stats/mix.exs as a path dependency, exactly
          {:text_stats, path: "../vendor/text_stats"}, keeping the existing
          lemieux path dependency and every other project setting. Do not modify
          anything under vendor/, line_stats/lib, line_stats/priv,
          line_stats/bench, line_stats/README.md or line_stats/.formatter.exs.
          Keep line_stats/lemieux-extension.json consistent with the export
          rules: it must still list mix.exs, every file it names must exist, and
          if you create a mix.lock you must list it too. Record the dependency,
          its relative path and the consumer prerequisite in
          line_stats/BUILDING.md. Do not run Mix, deps.get, compile, benchmark
          or launch model processes. Write outcome.json in this workspace with
          {"benchmarked":false,"qualification":"unassessed"}.
          """
        else
          """
          The extension in ./line_stats is a scaffolded Lemieux extension
          (LineStats) whose developer added a path dependency (see
          line_stats/mix.exs), a helper module, tests and a mix.lock, but never
          updated line_stats/lemieux-extension.json. Reconcile that manifest with
          the export rules: schema_version 1, module LineStats, and files naming
          exactly every file under lib/, priv/, test/ and bench/ plus mix.exs,
          mix.lock, .formatter.exs, README.md and BUILDING.md, each once; never
          list lemieux-extension.json itself or any export receipt. Do not modify
          any other file except line_stats/BUILDING.md, where you record the
          manifest reconciliation and the pending validation. Do not run Mix,
          deps.get, compile, benchmark or launch model processes. Write
          outcome.json in this workspace with
          {"benchmarked":false,"qualification":"unassessed"}.
          """
        end

      File.write!(Path.join(cwd, "brief.txt"), brief <> @authorized)
    end
  end

  defp maintenance(root) do
    cwd = Path.join(root, "models_reconcile")
    scaffold!(cwd, "report_digest", "Digest one report into five bullet points.")

    File.write!(
      Path.join(cwd, "bench/models.json"),
      ~s([{"model":"zai_coding_plan:glm-5.3","efforts":["ultra"]},) <>
        ~s({"model":"zai_coding_plan:glm-4.7","effort":"default"}]\n)
    )

    File.write!(
      Path.join(cwd, "BUILDING.md"),
      File.read!(Path.join(cwd, "BUILDING.md")) <>
        "\nDecision: compare only the developer's explicit shortlist; catalog entries are not entitlement.\n"
    )

    File.write!(
      Path.join(cwd, "brief.txt"),
      """
      Continue this scaffolded extension project (ReportDigest). Its
      bench/models.json is invalid: one entry names an unsupported effort and
      another uses a flat effort field instead of the grouped
      {"model": ..., "efforts": [...]} schema. The developer's explicit
      comparison shortlist, in this order, is zai_coding_plan:glm-4.7 at
      default effort, then zai_coding_plan:glm-5.3 at default effort. Write
      exactly that shortlist to bench/models.json using extension_workflow
      save_models, which validates and serializes it. Preserve
      priv/profile.json, lib/, README.md, mix.exs, lemieux-extension.json, the
      other bench files and the existing BUILDING.md decision; record the
      repair and the remaining comparison/confirmation work in BUILDING.md. Do
      not scaffold, run benchmarks, launch model processes, or infer a winner.
      Write outcome.json with {"benchmarked":false,"qualification":"unassessed"}.
      """ <> @authorized
    )

    cwd = Path.join(root, "scaffold_quota")
    File.mkdir_p!(cwd)

    File.write!(
      Path.join(cwd, "brief.txt"),
      """
      Create a new extension named log_triage in ./log_triage with the
      deterministic scaffold tool. The profile must be exactly: model
      zai_coding_plan:glm-5.3, tools read and bash only, system instructions
      "Triage one log file and name the first failing step.", 7 turns, 1536
      output tokens, temperature 0.1, low reasoning effort, and quota execution
      with max_requests 5 and no dollar cap (max_cost_usd null). Record in
      log_triage/BUILDING.md that the acceptance cases, the model/effort
      comparison and independent confirmation remain outstanding. Do not run,
      compile, benchmark or spend quota on the new extension. This is only an
      artifact-production test with explicit inputs.
      """ <> @authorized
    )
  end

  defp scaffold!(destination, name, system) do
    {:ok, _receipt} = Scaffold.create(destination, name, scaffold_profile(system))
    # The export receipt describes a package, not a workspace; a builder that
    # edits the project would only leave it stale, so the fixture omits it.
    File.rm!(Path.join(destination, "lemieux-extension-export.json"))
  end

  defp scaffold_profile(system) do
    %{
      "execution" => "live",
      "model" => "zai_coding_plan:glm-5.3",
      "tools" => ["read", "write", "edit", "bash"],
      "options" => %{
        "system" => system,
        "max_turns" => 12,
        "max_tokens" => 4096,
        "max_cost_usd" => 1.0,
        "reasoning_effort" => "default",
        "temperature" => 0.2
      }
    }
  end

  defp add_to_manifest!(root, files) do
    path = Path.join(root, "lemieux-extension.json")
    manifest = path |> File.read!() |> JSON.decode!()
    manifest = Map.put(manifest, "files", Enum.sort(Enum.uniq(manifest["files"] ++ files)))
    File.write!(path, JSON.encode!(manifest))
  end

  defp vendor_text_stats!(root) do
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule TextStats.MixProject do
      use Mix.Project

      def project, do: [app: :text_stats, version: "0.1.0", elixir: "~> 1.20", deps: []]
      def application, do: [extra_applications: []]
    end
    """)

    File.write!(Path.join(root, "lib/text_stats.ex"), """
    defmodule TextStats do
      @moduledoc "Deterministic text statistics shared by local extensions."

      @spec line_count(text :: String.t()) :: non_neg_integer()
      def line_count(text) when is_binary(text) do
        text |> String.split("\\n") |> Enum.count(&(&1 != ""))
      end
    end
    """)

    File.write!(Path.join(root, "README.md"), "# text_stats\n\nA local path dependency.\n")
  end

  defp word_count_source do
    """
    defmodule LineAudit.Tools.WordCount do
      @moduledoc "Counts whitespace-separated words in one workspace file."
      @behaviour Lemieux.Tool

      @impl true
      def name, do: "word_count"

      @impl true
      def description,
        do: "Count whitespace-separated words in a file relative to the workspace."

      @impl true
      def schema do
        %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Relative file path."}
          },
          "required" => ["path"],
          "additionalProperties" => false
        }
      end

      @impl true
      def parallel_safe?, do: true

      @impl true
      def read_only?, do: true

      @impl true
      def run(%{"path" => path}, context) when is_binary(path) do
        case File.read(Path.join(context.cwd, path)) do
          {:ok, text} -> {:ok, text |> String.split() |> length() |> Integer.to_string()}
          {:error, reason} -> {:error, "cannot read \#{path}: \#{inspect(reason)}"}
        end
      end

      def run(_args, _context), do: {:error, "path is required"}
    end
    """
  end
end

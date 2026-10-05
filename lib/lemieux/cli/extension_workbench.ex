defmodule Lemieux.CLI.ExtensionWorkbench do
  @moduledoc """
  A line-oriented local workbench over `Lemieux.Learning.Extension.Workbench`.

  Hosts can supply `:read` and `:write` functions to embed or test the interaction.
  EOF cancels the current action and exits, including at a live-run confirmation.
  Agent and grader execution happens only on `run`; cases and variant edits are
  persisted immediately. This command returns a status and never halts the VM.
  """

  alias Lemieux.Learning.Extension.Workbench
  alias Lemieux.Learning.Extension.Workbench.View

  @help "Commands: cases, variants, select, case, variant, run, reports, inspect, help, quit"

  @doc "Runs the interactive workbench using an already trusted configuration."
  @spec run(config :: keyword(), opts :: keyword()) :: non_neg_integer()
  def run(config, opts \\ []) do
    io = %{
      read: Keyword.get(opts, :read, &IO.gets/1),
      write: Keyword.get(opts, :write, &IO.puts/1)
    }

    case Workbench.open(config, Keyword.get(opts, :base_dir, File.cwd!())) do
      {:ok, state} ->
        emit(io, View.project(state))
        emit(io, @help)
        loop(state, io)

      {:error, reason} ->
        emit(io, "Cannot open workbench: #{inspect(reason)}")
        1
    end
  end

  defp loop(state, io) do
    case read(io, "workbench> ") do
      {:ok, command} when command in ["quit", "exit"] ->
        0

      {:ok, command} ->
        case dispatch(command, state, io) do
          {:ok, updated} ->
            loop(updated, io)

          :eof ->
            0

          {:error, reason} ->
            emit(io, "Action failed: #{inspect(reason)}")
            loop(state, io)
        end

      :eof ->
        0
    end
  end

  defp dispatch("help", state, io), do: show(state, io, @help)
  defp dispatch("", state, io), do: show(state, io, View.project(state))

  defp dispatch("cases", state, io) do
    lines =
      Enum.map(state.project["suite"]["tasks"], fn task ->
        "#{task["id"]}: #{task["prompt"]}\n  workspace: #{task["cwd"]}; timeout: #{task["timeout_ms"]} ms\n  grader: #{JSON.encode!(task["grader"]["command"])}"
      end)

    show(state, io, Enum.join(lines, "\n"))
  end

  defp dispatch("variants", state, io) do
    lines =
      state.project["variants"]
      |> Enum.sort()
      |> Enum.map(fn {name, variant} ->
        "#{name} (base #{variant["base"]}): #{JSON.encode!(variant["overrides"])}"
      end)

    show(state, io, Enum.join(lines, "\n"))
  end

  defp dispatch("select", state, io) do
    with {:ok, cases} <- read(io, "Case IDs, comma-separated: "),
         {:ok, variants} <- read(io, "Variant names, comma-separated (baseline first): "),
         {:ok, updated} <- Workbench.select(state, names(cases), names(variants)) do
      show(updated, io, View.project(updated))
    end
  end

  defp dispatch("case", state, io) do
    emit(
      io,
      "Add or replace a development case. Grader commands execute with your local authority."
    )

    with {:ok, id} <- read(io, "Case ID: "),
         existing = Enum.find(state.project["suite"]["tasks"], %{}, &(&1["id"] == id)),
         {:ok, prompt} <- field(io, "Task prompt", existing["prompt"]),
         {:ok, cwd} <- field(io, "Workspace path", existing["cwd"]),
         {:ok, timeout} <- field(io, "Timeout in ms", existing["timeout_ms"] || 60_000),
         {:ok, timeout} <- positive_integer(timeout),
         {:ok, command} <-
           field(io, "Grader argv as JSON (supports {answer}, {cwd})", grader_default(existing)),
         {:ok, command} <- JSON.decode(command),
         definition =
           existing
           |> Map.merge(%{"id" => id, "prompt" => prompt, "cwd" => cwd, "timeout_ms" => timeout})
           |> Map.put("grader", Map.put(existing["grader"] || %{}, "command", command)),
         {:ok, updated} <- Workbench.put_case(state, definition) do
      show(updated, io, "Saved case #{id}. Use select to include it in a comparison.")
    end
  end

  defp dispatch("variant", state, io) do
    emit(
      io,
      "Create or replace a variant. Blank tuning values inherit the configured agent's settings."
    )

    emit(
      io,
      "Configured bases: #{state.registry |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"
    )

    with {:ok, name} <- read(io, "Variant name: "),
         {:ok, base} <- read(io, "Configured base name: "),
         {:ok, model} <- read(io, "Model (blank to inherit): "),
         {:ok, system} <- read(io, "System instructions (blank to inherit): "),
         {:ok, turns} <- read(io, "Maximum turns (blank to inherit): "),
         {:ok, overrides} <- overrides(model, system, turns),
         {:ok, updated} <- Workbench.put_variant(state, name, base, overrides) do
      show(
        updated,
        io,
        "Saved variant #{name}. Extensions may constrain these requested settings. Use select to compare it."
      )
    end
  end

  defp dispatch("run", state, io) do
    emit(io, View.project(state))

    with {:ok, allowed} <- confirm(state, io),
         {:ok, report, id} <- Workbench.run(state, allow_live: allowed, progress: progress(io)) do
      show(
        state,
        io,
        "Saved run #{id}\nReport: #{Path.join([state.root, "runs", id, "report.json"])}\n#{View.summary(report)}"
      )
    end
  end

  defp dispatch("reports", state, io) do
    with {:ok, ids} <- Workbench.history(state) do
      show(state, io, if(ids == [], do: "No runs yet.", else: Enum.join(ids, "\n")))
    end
  end

  defp dispatch("inspect", state, io) do
    with {:ok, id} <- read(io, "Run ID (blank for latest): "),
         {:ok, id} <- run_id(state, id),
         {:ok, report} <- Workbench.report(state, id) do
      emit(io, View.summary(report))

      with {:ok, index} <- read(io, "Attempt number (blank to return): ") do
        inspect_attempt(state, io, report, index)
      end
    end
  end

  defp dispatch(_command, state, io), do: show(state, io, @help)

  defp inspect_attempt(state, _io, _report, ""), do: {:ok, state}

  defp inspect_attempt(state, io, report, index) do
    with {:ok, number} <- positive_integer(index),
         do: show(state, io, View.attempt(report, number))
  end

  defp confirm(%{execution: :scripted}, _io), do: {:ok, false}

  defp confirm(_state, io) do
    emit(
      io,
      "Live execution consumes account usage. The displayed limits control admission; extensions own their cumulative usage."
    )

    case read(io, "Type run-live to dispatch with the displayed budget: ") do
      {:ok, "run-live"} -> {:ok, true}
      {:ok, _other} -> {:error, :run_cancelled}
      :eof -> :eof
    end
  end

  defp progress(io) do
    fn event -> emit(io, progress_line(event)) end
  end

  defp progress_line(%{event: :attempt_started} = event),
    do: "Starting #{event.runtime} / #{event.task_id} / repetition #{event.attempt}"

  defp progress_line(%{event: :attempt_finished} = event),
    do:
      "Finished #{event.runtime} / #{event.task_id} / repetition #{event.attempt}: #{if event.passed, do: "passed", else: "not accepted"}"

  defp run_id(state, "") do
    case Workbench.history(state) do
      {:ok, [id | _]} -> {:ok, id}
      {:ok, []} -> {:error, :no_runs}
      error -> error
    end
  end

  defp run_id(_state, id), do: {:ok, id}

  defp overrides(model, system, turns) do
    result =
      %{"model" => model, "system" => system} |> Map.reject(fn {_key, value} -> value == "" end)

    if turns == "", do: {:ok, result}, else: put_turns(result, turns)
  end

  defp put_turns(result, turns) do
    with {:ok, value} <- positive_integer(turns), do: {:ok, Map.put(result, "max_turns", value)}
  end

  defp positive_integer(text) do
    case Integer.parse(to_string(text)) do
      {number, ""} when number > 0 -> {:ok, number}
      _invalid -> {:error, :positive_integer_required}
    end
  end

  defp grader_default(%{"grader" => %{"command" => command}}), do: JSON.encode!(command)
  defp grader_default(_case), do: nil

  defp field(io, label, default) do
    with {:ok, answer} <- read(io, "#{label}#{if default, do: " [#{default}]", else: ""}: ") do
      {:ok, if(answer == "" and not is_nil(default), do: to_string(default), else: answer)}
    end
  end

  defp names(text), do: text |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp show(state, io, text) do
    emit(io, text)
    {:ok, state}
  end

  defp emit(io, text), do: io.write.(View.clean(text))

  defp read(io, prompt) do
    case io.read.(View.clean(prompt)) do
      text when is_binary(text) -> {:ok, String.trim(text)}
      _eof -> :eof
    end
  end
end

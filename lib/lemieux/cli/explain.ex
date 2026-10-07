defmodule Lemieux.CLI.Explain do
  @moduledoc """
  Inspect the prepared harness without mounting a runtime or sending a model
  request. Selected extensions still execute trusted initialization code;
  this is not a safe way to inspect an untrusted extension.

  It reports the model `lmx run` would start on, chosen by the same function
  (`Lemieux.CLI.Run.resolve_model/2`) — which, when nothing named a model
  and no provider has a key, means asking a local Ollama daemon what it
  serves (`Lemieux.CLI.Models.local/2`, an HTTP request bounded to well
  under a second, and no model request). It used to skip that step to send
  nothing at all, and so reported a fallback model with a missing key on
  exactly the machines where `lmx run` went on to answer with a local
  model. The terminal UI chooses the same way, except behind `--base-url`
  or an Ixway route: there `lmx run` keeps the configured model for the
  gateway, while the terminal UI may still pick one, so this reports
  `lmx run`'s.

  A catalog that offers two tools under one name is an error here, not a
  line in the report: a session refuses to start with it (`Lemieux.Tool.
  validate_all/1`). The planning example's second `todo` stopped every
  session it was loaded into while `lmx explain` reported nothing wrong.
  """
  alias Lemieux.CLI
  alias Lemieux.CLI.Diagnostics
  alias Lemieux.CLI.Errors
  alias Lemieux.CLI.ExtensionExperience
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Run
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.Sanitize
  alias Lemieux.Harness

  @spec run(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def run(argv, opts) do
    with {:ok, options} <- Options.parse(argv, command: :explain),
         {:ok, opts} <- Runtime.with_routes(options, opts),
         {:ok, options, opts} <- ExtensionExperience.prepare(options, opts),
         options = Runtime.project_mcp(options, opts),
         options = Run.resolve_model(options, opts),
         # The workspace `lmx run` would compose over, saved plugins included,
         # so the report describes the session a run would start.
         {:ok, opts} <- Runtime.with_workspace(options, opts),
         {:ok, prepared} <- Runtime.prepare(options, opts),
         report =
           Harness.explain(prepared.harness, prepared.options)
           |> Map.put("diagnostics", Diagnostics.report(options, prepared)),
         {:ok, output} <- compare(report, options.given[:explain_against]) do
      IO.puts(output |> JSON.encode!() |> Sanitize.json())
      catalog(report, opts)
    else
      {:error, reason} -> fail(Errors.describe(reason, program: CLI.program(opts)), opts)
    end
  end

  defp compare(report, nil), do: {:ok, report}

  defp compare(report, path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"version" => 1} = previous} <- JSON.decode(bytes) do
      {:ok, %{"current" => report, "changes" => Harness.diff(previous, report)}}
    else
      _ -> {:error, "--explain-against needs a version 1 explanation report"}
    end
  end

  # After the report, so the whole catalog is there to read; the status says
  # a session would not start.
  defp catalog(%{"tools" => tools}, opts) when is_list(tools) do
    names = Enum.map(tools, & &1["name"])

    case Enum.uniq(names -- Enum.uniq(names)) do
      [] ->
        :ok

      duplicates ->
        duplicates
        |> Enum.map_join("; ", &duplicate(&1, tools))
        |> then(&fail("the tool catalog #{&1}, so a session would refuse to start", opts))
    end
  end

  defp catalog(_report, _opts), do: :ok

  defp duplicate(name, tools) do
    named = Enum.filter(tools, &(&1["name"] == name))

    from =
      Enum.map_join(
        named,
        ", ",
        &(&1["implementation"] |> List.wrap() |> List.last() |> to_string())
      )

    "offers #{length(named)} tools named #{name} (#{from}); leave all but one out " <>
      "(\"disabled_extensions\" names a shipped one) or rename the others"
  end

  defp fail(message, opts) do
    IO.puts(
      :stderr,
      Sanitize.for_device("lmx explain: " <> message, :stderr, opts[:terminal?])
    )

    {:error, 1}
  end
end

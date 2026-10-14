defmodule Lemieux.CLI.Status do
  @moduledoc """
  Provider-free extension status over the currently prepared local configuration.

  No session, MCP connection or provider request is started. Current selected
  extensions still run their trusted initialization code, as with `lmx explain`.
  This deliberately uses current configuration; callbacks are never recovered
  from a saved transcript. `/status` queries an existing live session instead.
  """
  alias Lemieux.CLI.Errors
  alias Lemieux.CLI.ExtensionExperience
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.Sanitize
  alias Lemieux.Contribution
  alias Lemieux.Contribution.Runtime, as: Contributions
  alias Lemieux.Conversation.Command.Status

  @spec run(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def run(argv, opts) do
    with {:ok, options} <- Options.parse(argv, command: :status),
         {:ok, opts} <- Runtime.with_routes(options, opts),
         {:ok, options, opts} <- ExtensionExperience.prepare(options, opts),
         {:ok, prepared} <- Runtime.prepare(options, opts),
         {:ok, runtime} <-
           Contributions.start(self(), prepared.harness.contributions || [], %{
             cwd: Keyword.get(prepared.options, :cwd, File.cwd!()),
             environment: prepared.harness.environment,
             session_id: nil
           }) do
      context = %{
        cwd: Keyword.get(prepared.options, :cwd, File.cwd!()),
        environment: prepared.harness.environment,
        session_id: nil
      }

      try do
        report =
          case options.argv do
            [] ->
              runtime |> Contributions.status(context) |> Contribution.format()

            [namespace, name | args] ->
              Contributions.command(runtime, namespace, name, Enum.join(args, " "), context)
              |> Status.format_result()

            _invalid ->
              "use lmx status [NAMESPACE COMMAND [ARGUMENTS]] [options]"
          end

        IO.puts(Sanitize.for_device(report, :stdio, opts[:terminal?]))
        :ok
      after
        Contributions.close(runtime)
      end
    else
      {:error, reason} ->
        IO.puts(
          :stderr,
          Sanitize.for_device(
            "lmx status: " <> Errors.describe(reason),
            :stderr,
            opts[:terminal?]
          )
        )

        {:error, 1}
    end
  end
end

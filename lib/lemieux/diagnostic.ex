defmodule Lemieux.Diagnostic do
  @moduledoc """
  Explicit provenance for unexpected Lemieux failures.

  A failed command, provider request, policy refusal or killed process is not
  evidence of a Lemieux defect. Only the boundary which observed a programming
  failure marks it. The stable identity travels with retries and child events
  so presentation and reporting can count the same fault once.
  """
  alias Lemieux.Contract
  alias Lemieux.ID

  @doc "Records an internal fault while retaining the complete local evidence."
  @spec new(component :: String.t(), message :: String.t(), details :: term()) :: map()
  def new(component, message, details) do
    %{
      "id" => ID.generate(),
      "source" => "lemieux",
      "category" => "internal",
      "component" => component,
      "message" => message,
      "details" => Contract.json(details),
      "original" => inspect(details, limit: :infinity, printable_limit: :infinity)
    }
  end

  @doc "Reads a marked fault without guessing from prose or an error flag."
  @spec from_payload(payload :: map()) :: map() | nil
  def from_payload(%{
        "diagnostic" =>
          %{"source" => "lemieux", "category" => "internal", "id" => id} = diagnostic
      })
      when is_binary(id), do: diagnostic

  def from_payload(_payload), do: nil

  @doc "Whether a process exit describes an exception in bundled Lemieux code."
  @spec internal_crash?(reason :: term()) :: boolean()
  def internal_crash?({%{__exception__: true}, [{module, _, _, _} | _]}) when is_atom(module),
    do: String.starts_with?(Atom.to_string(module), "Elixir.Lemieux.")

  def internal_crash?(_reason), do: false

  @doc "A hint for human interfaces; it never publishes anything."
  @spec hint() :: String.t()
  def hint, do: "Use /feedback bug to prepare a sanitized bug report."

  @doc "A completed turn's explicit error count."
  @spec summary(count :: pos_integer()) :: String.t()
  def summary(1),
    do:
      "There was 1 error during that turn. Use /feedback to submit sanitized feedback as a bug report to the repository."

  def summary(count),
    do:
      "There were #{count} errors during that turn. Use /feedback to submit sanitized feedback as a bug report to the repository."
end

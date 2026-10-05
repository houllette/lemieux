defmodule Lemieux.Tools.AskUser.Diagram do
  @moduledoc """
  Validates small text diagrams supplied with an `ask_user` question.

  The terminal must preserve columns for arrows and branches to make sense.
  A bounded, plain-text field gives the question panel enough room to show the
  diagram alongside every answer, and rejects control characters that could
  change the terminal's layout.
  """

  @max_lines 5
  @max_columns 72
  @max_length 512
  @error "ask_user diagram must be plain text with at most five lines, 72 columns per line, and 512 characters"

  @doc "The optional diagram schema, shared by single and batch questions."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => @max_length,
      "description" =>
        "Optional plain-text diagram, at most five lines and 72 columns. Use spaces and line breaks; do not use Markdown fences."
    }
  end

  @doc "Normalizes line endings while retaining diagram alignment."
  @spec normalize(value :: term()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def normalize(nil), do: {:ok, nil}

  def normalize(diagram) when is_binary(diagram) do
    normalized = String.replace(diagram, "\r\n", "\n")
    lines = String.split(normalized, "\n")

    if String.trim(normalized) != "" and String.length(normalized) <= @max_length and
         length(lines) <= @max_lines and
         Enum.all?(lines, &(String.length(&1) <= @max_columns)) and printable?(normalized),
       do: {:ok, normalized},
       else: {:error, @error}
  end

  def normalize(_value), do: {:error, @error}

  defp printable?(text) do
    text
    |> String.to_charlist()
    |> Enum.all?(fn code -> code == ?\n or (code >= 32 and code not in 127..159) end)
  end
end

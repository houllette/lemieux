defmodule Lemieux.MCP.Elicitation do
  @moduledoc """
  Answering a server that asks for something mid-call.

  A server may reply to `tools/call` with `input_required` rather than a
  result, carrying requests for what it still needs. The client satisfies what
  it can and retries the original call with the answers and the server's
  opaque `requestState` echoed back untouched.

  ## Only what was declared

  A server **must not** ask for a kind of input the client did not declare, and
  lemieux declares exactly one: **form-mode elicitation**. That is a question
  with a JSON Schema attached, which is the one thing a host already knows how
  to answer — `Lemieux.Session.park/4` asks it and `Lemieux.Session.answer/3`
  replies, the same path `Lemieux.Tools.AskUser` uses.

  Anything else is declined rather than guessed at. `url` mode wants a browser
  and a consent step a library cannot assume; sampling would mean lending the
  server lemieux's model and paying for its tokens; roots is deprecated. A
  conforming server will not ask, and one that asks anyway gets an honest
  `decline` instead of a fabricated answer.

  ## Turning a sentence into a form

  The person answering is typing into a terminal or an inbox, not filling in a
  form, so the answer arrives as text and has to be fitted to the schema:

    * one property — the text is that property's value, converted to its type;
    * several — the answer is read as JSON, since there is no other way to say
      which part is which;
    * neither works — `decline`, which is a thing the specification expects a
      client to say and a server to handle.

  Declining is always available and never a failure. The three actions mean
  different things to a server — `accept` submitted data, `decline` a refusal,
  `cancel` a dismissal — and a client that answered `accept` with invented
  content would be lying to it.
  """

  @doc """
  The question to put to a person for one elicitation request.

  Returns `:unsupported` for anything lemieux did not declare support for.
  """
  @spec question(request :: map(), server :: String.t()) :: {:ok, String.t()} | :unsupported
  def question(%{"method" => "elicitation/create", "params" => params}, server) do
    case Map.get(params, "mode", "form") do
      "form" -> {:ok, prompt(params, server)}
      _other -> :unsupported
    end
  end

  def question(_request, _server), do: :unsupported

  @doc """
  The title a request carries, when it carries one, for a host to show above
  its question.
  """
  @spec title(request :: map()) :: String.t() | nil
  def title(%{"params" => params}) when is_map(params) do
    case get_in(params, ["requestedSchema", "title"]) || Map.get(params, "title") do
      title when is_binary(title) and title != "" -> title
      _other -> nil
    end
  end

  def title(_request), do: nil

  @doc """
  The fields a request asks for — name, JSON Schema type and the server's
  description — so a host can show what was asked beside the question. The
  typed answer is still fitted to the schema by `response/2`; this only
  describes it.
  """
  @spec fields(request :: map()) :: [
          %{name: String.t(), type: String.t(), description: String.t() | nil}
        ]
  def fields(%{"params" => params}) when is_map(params) do
    Enum.map(properties(params), fn {name, schema} ->
      %{
        name: name,
        type: Map.get(schema, "type", "string"),
        description: description(schema)
      }
    end)
  end

  def fields(_request), do: []

  defp description(%{"description" => description}) when is_binary(description), do: description
  defp description(_schema), do: nil

  defp prompt(params, server) do
    message = Map.get(params, "message", "the #{server} server needs some information")

    case properties(params) do
      [] ->
        "#{server} asks: #{message}"

      [field] ->
        "#{server} asks: #{message} (#{describe(field)})"

      many ->
        "#{server} asks: #{message}\nAnswer as JSON with: #{Enum.map_join(many, ", ", &describe/1)}"
    end
  end

  defp describe({name, schema}) do
    case Map.get(schema, "type", "string") do
      "string" -> name
      type -> "#{name}: #{type}"
    end
  end

  defp properties(params) do
    params
    |> Map.get("requestedSchema", %{})
    |> Map.get("properties", %{})
    |> Enum.to_list()
  end

  @doc """
  Builds the response to one request from the answer a person gave.

  `{:error, _}` from the asking becomes a `decline`, which is what a client
  says when it could not get an answer.
  """
  @spec response(request :: map(), answer :: {:ok, String.t()} | {:error, term()}) :: map()
  def response(_request, {:error, _reason}), do: %{"action" => "decline"}

  def response(%{"params" => params}, {:ok, answer}) do
    case content(properties(params), answer) do
      {:ok, content} -> %{"action" => "accept", "content" => content}
      :error -> %{"action" => "decline"}
    end
  end

  def response(_request, _answer), do: %{"action" => "decline"}

  @doc """
  The response for a request lemieux cannot satisfy.
  """
  @spec declined() :: map()
  def declined, do: %{"action" => "decline"}

  # No schema to fit: the server asked for consent rather than data.
  defp content([], _answer), do: {:ok, %{}}

  defp content([{name, schema}], answer) do
    case cast(answer, Map.get(schema, "type", "string")) do
      {:ok, value} -> {:ok, %{name => value}}
      :error -> :error
    end
  end

  defp content(_fields, answer) do
    case JSON.decode(answer) do
      {:ok, content} when is_map(content) -> {:ok, content}
      _otherwise -> :error
    end
  end

  defp cast(answer, "string"), do: {:ok, answer}

  defp cast(answer, "boolean") do
    case answer |> String.trim() |> String.downcase() do
      yes when yes in ~w(true yes y) -> {:ok, true}
      no when no in ~w(false no n) -> {:ok, false}
      _otherwise -> :error
    end
  end

  defp cast(answer, type) when type in ~w(number integer) do
    trimmed = String.trim(answer)

    case {Integer.parse(trimmed), Float.parse(trimmed)} do
      {{value, ""}, _float} -> {:ok, value}
      {_integer, {value, ""}} -> {:ok, value}
      _otherwise -> :error
    end
  end

  defp cast(answer, _type), do: {:ok, answer}
end

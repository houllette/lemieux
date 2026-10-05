defmodule Lemieux.TUI.MCPForm do
  @moduledoc """
  The MCP add questionnaire, built from the same questions and staged answers
  as `Lemieux.TUI.QuestionFlow`. Transport selects the remaining tabs; changing
  it drops fields that belong to the other transport before review.
  """

  alias Lemieux.TUI.QuestionFlow

  @doc "Starts the name and transport tabs."
  @spec new() :: map()
  def new do
    %{questions: initial_questions()}
    |> QuestionFlow.new("")
    |> Map.merge(%{kind: :mcp, transport: nil, notice: nil})
  end

  @doc "Adds transport-specific tabs after a single transport choice."
  @spec expand_transport(flow :: map()) :: map()
  def expand_transport(flow) do
    [transport] = get_in(flow.answers, ["transport", "selected"])

    answers =
      if flow.transport == transport,
        do: flow.answers,
        else: Map.take(flow.answers, ["name", "transport"])

    questions =
      %{questions: initial_questions() ++ transport_questions(transport) ++ [scope_question()]}
      |> QuestionFlow.new("")
      |> Map.fetch!(:questions)

    %{
      flow
      | questions: questions,
        answers: answers,
        index: 2,
        review?: false,
        other?: true,
        review_index: length(questions),
        transport: transport
    }
  end

  @doc "Checks and normalizes a text tab before QuestionFlow stages it."
  @spec text_answer(question_id :: String.t(), value :: String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def text_answer("name", value) do
    value = String.trim(value)

    if Regex.match?(~r/^[A-Za-z0-9_.-]+$/, value),
      do: {:ok, value},
      else: {:error, "Enter a name using letters, numbers, dot, dash or underscore."}
  end

  def text_answer("url", value) do
    value = String.trim(value)
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host),
      do: {:ok, value},
      else: {:error, "Enter an absolute http:// or https:// URL."}
  end

  def text_answer("command", value) do
    value = String.trim(value)
    if value == "", do: {:error, "Enter an executable command."}, else: {:ok, value}
  end

  def text_answer("args", value),
    do: json_answer(value, [], &valid_args?/1, "JSON array of strings")

  def text_answer(id, value) when id in ["headers", "env"],
    do: json_answer(value, %{}, &valid_object?/1, "JSON object with string values")

  @doc "Builds the JSON-shaped server configuration from reviewed answers."
  @spec server(flow :: map()) :: map()
  def server(flow) do
    answers = flow.answers
    name = answers["name"]["text"]
    [transport] = answers["transport"]["selected"]
    common = %{"name" => name, "transport" => transport}

    case transport do
      "http" ->
        Map.merge(common, %{
          "url" => answers["url"]["text"],
          "headers" => JSON.decode!(answers["headers"]["text"])
        })

      "stdio" ->
        Map.merge(common, %{
          "command" => answers["command"]["text"],
          "args" => JSON.decode!(answers["args"]["text"]),
          "env" => JSON.decode!(answers["env"]["text"])
        })
    end
  end

  @doc """
  Where the reviewed server is saved: `"personal"` — the person's own
  configuration, which every repository shares and none can read — or
  `"project"`, the repository's `.mcp.json`, which anybody who clones it
  gets. Personal is the default, because a server somebody adds for
  themselves is theirs, and a repository file with their credentials in it
  is one commit away from being everybody's.
  """
  @spec scope(flow :: map()) :: String.t()
  def scope(flow) do
    case get_in(flow.answers, ["scope", "selected"]) do
      ["project"] -> "project"
      _personal -> "personal"
    end
  end

  @doc """
  Replaces secret-looking values in a server's headers and environment
  with `${NAME}` references, returning the rewritten server and the values
  withheld.

  A value is withheld when its key names a credential (`KEY`, `TOKEN`,
  `SECRET`, `PASSWORD`, `AUTHORIZATION`) or it reads like one (a bearer
  token, a long unbroken run of letters and digits). The configuration keeps
  only the reference; the caller puts the values in this process's
  environment so the server connects now, and tells the person which
  variables to export for next time.
  """
  @spec withheld(server :: map()) :: {map(), [{String.t(), String.t()}]}
  def withheld(%{"name" => name} = server) do
    {headers, from_headers} = withhold_headers(Map.get(server, "headers", %{}), name)
    {env, from_env} = withhold_env(Map.get(server, "env", %{}))

    server =
      server
      |> maybe_put("headers", headers, Map.has_key?(server, "headers"))
      |> maybe_put("env", env, Map.has_key?(server, "env"))

    {server, from_headers ++ from_env}
  end

  defp maybe_put(server, key, value, true), do: Map.put(server, key, value)
  defp maybe_put(server, _key, _value, false), do: server

  defp withhold_headers(headers, server_name) do
    Enum.map_reduce(headers, [], fn {key, value}, withheld ->
      if secret?(key, value) and not reference?(value) do
        variable = variable_name(server_name, key)
        {scheme, token} = split_scheme(value)
        {{key, scheme <> "${#{variable}}"}, [{variable, token} | withheld]}
      else
        {{key, value}, withheld}
      end
    end)
    |> then(fn {pairs, withheld} -> {Map.new(pairs), Enum.reverse(withheld)} end)
  end

  defp withhold_env(env) do
    Enum.map_reduce(env, [], fn {key, value}, withheld ->
      if secret?(key, value) and not reference?(value),
        do: {{key, "${#{key}}"}, [{key, value} | withheld]},
        else: {{key, value}, withheld}
    end)
    |> then(fn {pairs, withheld} -> {Map.new(pairs), Enum.reverse(withheld)} end)
  end

  defp secret?(key, value) do
    Regex.match?(~r/key|token|secret|password|authorization|auth/i, key) or
      Regex.match?(~r/^(bearer|token)\s+\S{12,}$/i, value) or
      Regex.match?(~r/^[A-Za-z0-9_\-]{32,}$/, value)
  end

  defp reference?(value), do: String.contains?(value, "${")

  defp split_scheme(value) do
    case Regex.run(~r/^((?:bearer|token)\s+)(\S+)$/i, value, capture: :all_but_first) do
      [scheme, token] -> {scheme, token}
      nil -> {"", value}
    end
  end

  defp variable_name(server, header) do
    [server, header]
    |> Enum.map_join("_", &String.replace(&1, ~r/[^A-Za-z0-9]+/, "_"))
    |> String.upcase()
    |> then(&"MCP_#{&1}")
  end

  defp scope_question do
    %{
      question_id: "scope",
      question: "Where should this server be saved?",
      type: "single_choice",
      allow_other?: false,
      options: [
        %{
          id: "personal",
          label: "My settings",
          description: "~/.lmx/config.json: yours, in every repository"
        },
        %{
          id: "project",
          label: "This repository",
          description: ".mcp.json: anybody who clones it gets it"
        }
      ]
    }
  end

  defp json_answer(value, default, valid?, description) do
    value = if String.trim(value) == "", do: JSON.encode!(default), else: String.trim(value)

    case JSON.decode(value) do
      {:ok, decoded} ->
        if valid?.(decoded), do: {:ok, value}, else: {:error, "Enter a #{description}."}

      {:error, _reason} ->
        {:error, "Enter a #{description}."}
    end
  end

  defp valid_args?(args) when is_list(args), do: Enum.all?(args, &is_binary/1)
  defp valid_args?(_value), do: false

  defp valid_object?(object) when is_map(object),
    do: Enum.all?(object, fn {_key, value} -> is_binary(value) end)

  defp valid_object?(_value), do: false

  defp initial_questions do
    [
      %{question_id: "name", question: "Server name", type: "text"},
      %{
        question_id: "transport",
        question: "How does Lemieux connect to this server?",
        type: "single_choice",
        allow_other?: false,
        options: [
          %{id: "http", label: "HTTP", description: "Connect to a server URL"},
          %{id: "stdio", label: "stdio", description: "Run a local command"}
        ]
      }
    ]
  end

  defp transport_questions("http") do
    [
      %{question_id: "url", question: "Server URL", type: "text"},
      %{question_id: "headers", question: "HTTP headers as JSON (optional)", type: "text"}
    ]
  end

  defp transport_questions("stdio") do
    [
      %{question_id: "command", question: "Executable command", type: "text"},
      %{question_id: "args", question: "Arguments as JSON array (optional)", type: "text"},
      %{question_id: "env", question: "Environment as JSON object (optional)", type: "text"}
    ]
  end
end

defmodule Lemieux.WebSearch.Backends.Scripted do
  @moduledoc """
  Deterministic in-memory web-search backend for tests and examples.

  Each script item is a backend return value or an arity-two function receiving
  `(query, opts)`. Calls are retained in order so a test can assert the exact
  normalized query and restrictions that crossed the backend boundary.
  """

  @behaviour Lemieux.WebSearch.Backend

  @type response ::
          {:ok, [Lemieux.WebSearch.Result.t()], map()}
          | {:error, term()}
          | (String.t(), keyword() ->
               {:ok, [Lemieux.WebSearch.Result.t()], map()} | {:error, term()})

  @doc "Starts a scripted backend and returns its backend state."
  @spec new(script :: [response()]) :: pid()
  def new(script) when is_list(script) do
    {:ok, backend} = Agent.start_link(fn -> %{script: script, requests: []} end)
    backend
  end

  @doc "Returns normalized requests in call order."
  @spec requests(backend :: pid()) :: [{String.t(), keyword()}]
  def requests(backend) when is_pid(backend) do
    Agent.get(backend, &Enum.reverse(&1.requests))
  end

  @impl Lemieux.WebSearch.Backend
  def search(backend, query, opts) when is_pid(backend) do
    response =
      Agent.get_and_update(backend, fn
        %{script: [response | rest], requests: requests} = state ->
          {response, %{state | script: rest, requests: [{query, opts} | requests]}}

        %{script: [], requests: requests} = state ->
          {{:error, :script_exhausted}, %{state | requests: [{query, opts} | requests]}}
      end)

    if is_function(response, 2), do: response.(query, opts), else: response
  end
end

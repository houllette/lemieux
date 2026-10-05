defmodule Lemieux.CLI.State do
  @moduledoc """
  The little that `lmx` remembers between runs, beside the personal config.

  The model the person last chose, so somebody who started on
  `openai:gpt-6-sol` once — with `--model` or `LMX_MODEL`, say — is not put
  back on whatever `Lemieux.CLI.Models` would pick for them the next time
  they type `lmx`; the models sessions recently started on, whoever chose
  them; and the version the terminal UI last started, so it can say when
  `lmx` was updated in between. It lives in `state.json` in the personal
  state directory (`~/.lmx`, see `Lemieux.CLI.Options`), not in
  `config.json`, because it is a record of what happened rather than a
  setting: `lmx` rewrites it on every start, and a person editing their
  config should never find it churning.

  ## Chosen, and merely used

  The two model records are kept apart on purpose. `last_model` is a choice,
  and it outranks every guess on the next start. A model `lmx` picked by
  itself — the first provider with a key, a model Ollama happened to serve,
  the built-in default — is only *used*: it goes on the `recent_models` list,
  which breaks ties between local models (`Lemieux.CLI.Models.local/2`), and
  never becomes the choice. When it did, one session on an auto-selected
  local model was enough for a key set afterwards to be ignored on every
  later start, and a stopped Ollama to fail them with `connection refused`.

  The file is private (0600) and written through a temporary file and a
  rename, so two `lmx` processes starting at once leave one of their answers
  rather than half of each. It is advisory: a missing, unreadable or
  malformed file reads as "nothing remembered", and a failed write is not an
  error — forgetting the last model is a nuisance, refusing to start over it
  would be a bug.

  A `nil` directory remembers nothing. That is what `--config none` means
  (`Lemieux.CLI.Options.state_dir/1`): a run that reads no personal settings
  also leaves no personal trace, which is what keeps the test suite, CI jobs
  and other hermetic runs from depending on, or changing, the machine's home
  directory.
  """

  @file_name "state.json"
  # Enough to cover the local models one machine switches between; the list
  # is consulted for ordering only, so an older entry falling off loses
  # nothing but a tie-break.
  @recent_limit 10

  @doc "Where the state file lives in `state_dir`."
  @spec path(state_dir :: Path.t()) :: Path.t()
  def path(state_dir) when is_binary(state_dir), do: Path.join(state_dir, @file_name)

  @doc "The model the person last chose, or `nil`."
  @spec last_model(state_dir :: Path.t() | nil) :: String.t() | nil
  def last_model(nil), do: nil

  def last_model(state_dir) when is_binary(state_dir) do
    case read(state_dir) do
      %{"last_model" => model} when is_binary(model) and model != "" -> model
      _nothing -> nil
    end
  end

  @doc "The models sessions recently started on, most recent first."
  @spec recent_models(state_dir :: Path.t() | nil) :: [String.t()]
  def recent_models(nil), do: []

  def recent_models(state_dir) when is_binary(state_dir) do
    case read(state_dir) do
      %{"recent_models" => models} when is_list(models) ->
        Enum.filter(models, &(is_binary(&1) and &1 != ""))

      _nothing ->
        []
    end
  end

  @doc """
  Records that a session started on `model`: always on the recent list, and
  as the last model only when `chosen?: true` (the default) says a person
  chose it. See "Chosen, and merely used" in the module documentation.

  Returns `:ok` whether or not the write succeeded; see the module
  documentation for why.
  """
  @spec remember_model(state_dir :: Path.t() | nil, model :: String.t() | nil, opts :: keyword()) ::
          :ok
  def remember_model(state_dir, model, opts \\ [])
  def remember_model(nil, _model, _opts), do: :ok
  def remember_model(_state_dir, nil, _opts), do: :ok

  def remember_model(state_dir, model, opts) when is_binary(state_dir) and is_binary(model) do
    state = read(state_dir)
    recent = Enum.take([model | List.delete(recent(state), model)], @recent_limit)

    updated =
      if Keyword.get(opts, :chosen?, true),
        do: Map.merge(state, %{"version" => 1, "last_model" => model, "recent_models" => recent}),
        else: Map.merge(state, %{"version" => 1, "recent_models" => recent})

    if updated != state do
      _written = write(state_dir, updated)
    end

    :ok
  end

  defp recent(%{"recent_models" => models}) when is_list(models),
    do: Enum.filter(models, &is_binary/1)

  defp recent(_state), do: []

  @doc """
  Records `version` as the one the terminal UI last started, and says how it
  compares with the one recorded before: `{:updated, previous}` when this
  one is newer, `:unchanged` otherwise — the same version, an older one, a
  first start, or a state file from before versions were kept, none of
  which is news. Advisory like the model: a failed write is not an error,
  and a version that does not parse is compared as text.
  """
  @spec record_version(state_dir :: Path.t() | nil, version :: String.t()) ::
          {:updated, previous :: String.t()} | :unchanged
  def record_version(nil, _version), do: :unchanged

  def record_version(state_dir, version) when is_binary(state_dir) and is_binary(version) do
    state = read(state_dir)
    previous = state["lmx_version"]

    if previous != version do
      _written = write(state_dir, Map.merge(state, %{"version" => 1, "lmx_version" => version}))
    end

    if is_binary(previous) and newer?(version, previous),
      do: {:updated, previous},
      else: :unchanged
  end

  defp newer?(version, previous) do
    case {Version.parse(version), Version.parse(previous)} do
      {{:ok, current}, {:ok, earlier}} -> Version.compare(current, earlier) == :gt
      _unparsed -> version != previous
    end
  end

  defp read(state_dir) do
    with {:ok, content} <- File.read(path(state_dir)),
         {:ok, %{} = state} <- JSON.decode(content) do
      state
    else
      _missing_or_malformed -> %{}
    end
  end

  defp write(state_dir, state) do
    target = path(state_dir)
    temporary = target <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    try do
      with :ok <- File.mkdir_p(state_dir),
           :ok <- File.write(temporary, JSON.encode!(state) <> "\n", [:exclusive]),
           :ok <- File.chmod(temporary, 0o600) do
        File.rename(temporary, target)
      end
    after
      File.rm(temporary)
    end
  end
end

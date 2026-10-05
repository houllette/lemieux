defmodule Lemieux.CLI.Models do
  @moduledoc """
  Which model `lmx` starts with when nobody said, and whether it can reach it.

  The built-in default used to be one vendor's model whatever keys a machine
  had, so a person with only `OPENAI_API_KEY` set opened `lmx`, typed a
  question, and was told another vendor's key was missing. The fix is an
  order of preference, applied only when no flag, `LMX_MODEL`, config file
  or Ixway route chose the model (`Lemieux.CLI.Options` records which one
  did, as `:model_source`):

    1. the model the person last chose (`Lemieux.CLI.State`), if it can
       still be reached: its provider has a key, or, for a local Ollama
       model, the daemon is serving it — which only `local/2` can check,
       since it asks over HTTP;
    2. the recommended model of the first provider in `recommended/0` whose
       key is set — in the environment, in `:req_llm`'s configuration, or
       saved in the config file's `"providers"`;
    3. a model the local Ollama daemon serves that can call tools (`local/2`,
       which asks over HTTP and is therefore the hosts' call, not option
       parsing's; `Lemieux.CLI.Ollama.local_model/2` says which tag). The
       start says so in a notice that also says what the daemon's window
       needs: unless told otherwise Ollama serves 4096 tokens on a machine
       with less than about 23 GiB of GPU memory, and a session that
       outgrows its window loses its task without an error;
    4. the first row of `recommended/0`, as a placeholder: the terminal UI
       opens its provider panel (`first_run/2`) with no row selected, and
       `lmx run` stops with `missing_key_message/2`, which names no single
       vendor.

  ## The order of `recommended/0`

  Anthropic and OpenAI first, because those are the keys a newcomer most
  likely holds already; the others keep the order they had. The order
  decides which key wins when several are set and which model a keyless
  start holds as its placeholder — and nothing else: the panel preselects no
  row, and the no-key message lists choices rather than recommending one.
  It used to put Z.AI Coding Plan first, the historical default, "so nobody
  who relied on it is moved", a reason that held only while nobody outside
  the project used `lmx`. It is one table, which `lmx help models` renders
  and nothing else duplicates — a list in the docs that disagreed with the
  code was how the quickstart kept recommending a 2024 model.

  ## Chosen, and merely used

  Only a model a person chose is remembered as the one to start on next
  time (`remember/2`). A model this module picked — steps 2 to 4 — is
  recorded as used and nothing more (`Lemieux.CLI.State`): one session on an
  auto-selected local model used to make every later start ignore a key set
  in between, and fail with `connection refused` once Ollama was stopped. A
  remembered local model is also checked against what the daemon serves
  before it is used (`Lemieux.CLI.Ollama.serving/3`, which compares names as
  Ollama does, so `ollama:llama3.2` is the `llama3.2:latest` it lists), so a
  person whose earlier choice was local is not held to it once Ollama has
  gone away. Moving them off it is said, as a startup warning
  (`Lemieux.CLI.Config.warn/2`), naming the model and what was started on
  instead: their choice is still remembered, and a start that quietly went
  to a paid provider instead of the local model they picked would be a
  surprise on the bill.

  ## Hermetic runs

  None of this happens under `--config none`: no personal settings, no
  remembered model and no guessing from ambient credentials or a local
  daemon, so a script or a test gets the documented default and the same
  answer on every machine. A default config file that could not be created
  is not that (`Lemieux.CLI.Config.personal?/1`): steps 2 to 4 still apply,
  and only step 1, whose memory has nowhere to live, is skipped.
  """

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Ollama
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.State
  alias Lemieux.ModelSpec

  @recommended [
    %{provider: "anthropic", model: "anthropic:claude-sonnet-5", label: "Anthropic"},
    %{provider: "openai", model: "openai:gpt-6-sol", label: "OpenAI"},
    %{provider: "google", model: "google:gemini-3.8-flash", label: "Google Gemini"},
    %{provider: "xai", model: "xai:grok-4.7", label: "xAI"},
    %{
      provider: "openrouter",
      model: "openrouter:anthropic/claude-sonnet-5",
      label: "OpenRouter"
    },
    %{provider: "deepseek", model: "deepseek:deepseek-v4-pro", label: "DeepSeek"},
    %{provider: "zai_coding_plan", model: "zai_coding_plan:glm-5.3", label: "Z.AI Coding Plan"}
  ]

  # What chose a model when this module did rather than a person; see
  # "Chosen, and merely used".
  @guessed [:fallback, :credential, :ollama]

  # Unless told otherwise, Ollama serves a window sized by GPU memory — 4096
  # tokens under about 23 GiB, 32768 under about 47 GiB (Ollama's thresholds
  # for its nominal 24 and 48 GiB tiers; `Lemieux.Providers.OllamaWindow`) —
  # and a longer request loses its beginning without an error, so a coding
  # session loses its task. Every offer of a local model says so, in these
  # words.
  @local_window "set OLLAMA_CONTEXT_LENGTH to 32768 or more (65536 recommended)"

  @typedoc "One provider `lmx` knows how to start on, in preference order."
  @type recommendation :: %{
          provider: String.t(),
          model: String.t(),
          label: String.t(),
          env: String.t() | nil
        }

  @typedoc "Whether a provider's credential can be found."
  @type credential :: :present | :missing | :not_required | :unknown

  @doc """
  The providers `lmx` can pick a default for, in preference order, each with
  its recommended model and the environment variable its key is read from.
  """
  @spec recommended() :: [recommendation()]
  def recommended, do: Enum.map(@recommended, &Map.put(&1, :env, env_variable(&1.provider)))

  @doc """
  Resolves the model when nothing chose one, per the module documentation,
  without asking the network: steps 1 and 2.

  Returns the options unchanged when a flag, the environment, the config
  file or an Ixway route chose the model, or for a hermetic run
  (`--config none`). Otherwise `model` and `model_source` are replaced.

  `opts` may carry `:env`, a map read instead of the process environment,
  which is how the order is tested without depending on the machine.
  """
  @spec resolve(options :: Options.t(), opts :: keyword()) :: Options.t()
  def resolve(%Options{host: %{model_source: :fallback}} = options, opts) do
    if choosing?(options), do: guess(options, opts), else: options
  end

  def resolve(%Options{} = options, _opts), do: options

  defp guess(options, opts) do
    last = State.last_model(options.host.state_dir)

    cond do
      is_binary(last) and reachable?(last, options.config, opts) ->
        source(%{options | model: last}, :last_used)

      recommendation = first_available(options.config, opts) ->
        source(%{options | model: recommendation.model}, :credential)

      true ->
        options
    end
  end

  @doc """
  The steps of the module documentation that ask the local Ollama daemon,
  applied after `resolve/2`.

  A `:fallback` model whose provider has no key moves onto the tag
  `Lemieux.CLI.Ollama.local_model/2` picks, if the daemon serves one that
  can call tools. A remembered (`:last_used`) local model stays only while
  the daemon serves it; otherwise the model is resolved again without it —
  a provider with a key, another local model, or the placeholder. Either
  way `host.local_model` records what discovery read about the local model
  started on, its trained context length among it, and a move is said in a
  startup notice (`Lemieux.CLI.Config.warn/2`, which the hosts print).

  Asking is an HTTP request, bounded as `Lemieux.CLI.Ollama` says, and a
  person who named a model gets that model or an error, not a substitute.
  `opts` may carry `:env` as `resolve/2` does, and `:ollama`, the options
  handed to `Lemieux.CLI.Ollama` — `:get` and `:post` in place of
  `Req.get/2` and `Req.post/2`, for tests. Only that key reaches it, so an
  option meant for another of the host's requests never answers for the
  daemon.
  """
  @spec local(options :: Options.t(), opts :: keyword()) :: Options.t()
  def local(%Options{host: %{model_source: :fallback}} = options, opts) do
    with true <- choosing?(options),
         :missing <- credential(ModelSpec.provider(options.model), options.config, opts),
         {:ok, served} <- Ollama.local_model(options, ollama_opts(options, opts)) do
      options
      |> Map.put(:model, served.model)
      |> source(:ollama)
      |> local_model(served)
      |> warn(
        "Using #{served.model}, a model the local Ollama serves, as no API key was found; " <>
          "#{@local_window} for the Ollama server, or long sessions silently lose their " <>
          "task · --model or /model chooses another"
      )
    else
      _hermetic_keyed_or_nothing_served -> options
    end
  end

  def local(%Options{host: %{model_source: :last_used}} = options, opts) do
    if ModelSpec.provider(options.model) == "ollama",
      do: remembered_local(options, opts),
      else: options
  end

  def local(%Options{} = options, _opts), do: options

  defp remembered_local(options, opts) do
    case Ollama.serving(options, options.model, Keyword.get(opts, :ollama, [])) do
      {:ok, served} -> local_model(options, served)
      {:error, reason} -> unremembered(options, opts, reason)
    end
  end

  # Steps 2 to 4 again, as if nothing had been remembered: the person's
  # local model is not being served, and a key they have set since, or
  # another local model, is better than a start that cannot connect. A
  # daemon that did not answer is not asked again for another model.
  defp unremembered(options, opts, reason) do
    placeholder = source(%{options | model: Options.default_model()}, :fallback)

    instead =
      case {first_available(options.config, opts), reason} do
        {nil, :unreachable} ->
          placeholder

        {nil, :none} ->
          local(placeholder, opts)

        {recommendation, _reason} ->
          source(%{placeholder | model: recommendation.model}, :credential)
      end

    warn(instead, unserved(options.model, reason, instead))
  end

  # Said as the notice box says a warning: what happened, then "; " and
  # what to do about it, which it draws on a line of its own.
  defp unserved(model, reason, instead) do
    {why, remedy} =
      case reason do
        :unreachable ->
          {"Ollama did not answer", "start Ollama to use it again"}

        :none ->
          {"Ollama serves no chat model by that name",
           "`ollama pull #{ModelSpec.model_id(model)}` brings it back"}
      end

    started =
      if instead.host.model_source == :fallback,
        do: "",
        else: ", so this session starts on #{instead.model}"

    "#{model}, the model you last chose, is not available (#{why})#{started}; " <>
      "#{remedy}, or choose a model with --model or /model"
  end

  # A startup notice, through the warnings the host already shows
  # (`Lemieux.CLI.Config.warn/2`).
  defp warn(options, notice), do: %{options | config: Config.warn(options.config, notice)}

  defp ollama_opts(options, opts) do
    opts
    |> Keyword.get(:ollama, [])
    |> Keyword.put_new_lazy(:recent, fn -> State.recent_models(options.host.state_dir) end)
  end

  @doc """
  Records that a session started on `model`, as the model to start on next
  time only when a person chose it; see "Chosen, and merely used".
  """
  @spec remember(options :: Options.t(), model :: String.t() | nil) :: :ok
  def remember(%Options{host: %{state_dir: dir, model_source: source}}, model),
    do: State.remember_model(dir, model, chosen?: source not in @guessed)

  @doc """
  Whether `provider`'s credential can be found without asking the network.

  `:not_required` for providers that take none (a local daemon), `:unknown`
  for a name `req_llm` does not know — neither is reported as missing.

  A key comes from `:req_llm`'s configuration or the environment, else from
  the config file's `"providers"`. A variable that is set but empty is
  `:missing` even with a key saved: `Lemieux.Providers.ReqLLM` reads it as
  access switched off and will not fall back to the saved key, so counting
  that key here started sessions whose every request was refused.
  """
  @spec credential(provider :: String.t() | nil, config :: Config.t() | nil, opts :: keyword()) ::
          credential()
  def credential(provider, config, opts \\ [])
  def credential(nil, _config, _opts), do: :unknown

  def credential(provider, config, opts) when is_binary(provider) do
    # Transport aliases use the same credential identity as the provider path.
    name = if provider == "ollama_cloud", do: "ollama", else: provider

    case known_provider(name) do
      nil -> :unknown
      atom -> credential_for(atom, provider, config, opts)
    end
  end

  defp credential_for(atom, provider, config, opts) do
    if key_required?(atom, provider) do
      env = ReqLLM.Keys.env_var_name(atom)

      ambient =
        Application.get_env(:req_llm, ReqLLM.Keys.config_key(atom)) || getenv(env, opts)

      key = if is_nil(ambient), do: Config.api_keys(config)[provider], else: ambient
      if present?(key), do: :present, else: :missing
    else
      :not_required
    end
  end

  defp key_required?(atom, provider) do
    {:ok, module} = ReqLLM.provider(atom)

    provider == "ollama_cloud" or
      (Code.ensure_loaded?(module) and function_exported?(module, :default_env_key, 0))
  end

  @doc """
  What `lmx run` says when the model it would start on has no key.

  Three cases, because the way forward differs:

    * nobody chose the model — the placeholder of step 4 — so the sentence
      names no single vendor: no credentials were found, and the ways
      forward are a key from `lmx help models` (whose two examples are the
      first two rows of `recommended/0`, so the sentence follows the table),
      the terminal UI's panel, a local model, or `--model`;
    * a hermetic run (`--config none`), which looks at no keys and no local
      daemon and saves nothing, so "no credentials found" would be false
      with another provider's key set and the panel and Ollama are no way
      out: it says what the run starts on and what that needs;
    * a person named the model: its provider's key, or another model. Not
      "save one with /provider" — `/provider` switches providers and saves
      no key; the first-run panel is the only thing that does.

  `program` is how the help command is spelled — `mix lmx` in a source
  checkout. It never offers `/retry`: retrying cannot conjure a key.
  """
  @spec missing_key_message(options :: Options.t(), program :: String.t()) :: String.t()
  def missing_key_message(options, program \\ "lmx")

  def missing_key_message(%Options{host: %{model_source: :fallback}} = options, program) do
    if choosing?(options) do
      examples = recommended() |> Enum.take(2) |> Enum.map_join(" or ", & &1.env)

      "no model credentials found: set a provider's API key, such as #{examples} " <>
        "(#{program} help models lists them all, and #{program} in a terminal saves one for you), " <>
        "start Ollama with a model that can call tools, or choose a model with --model PROVIDER:MODEL"
    else
      "--config none starts on #{options.model} and picks no model from your keys or a " <>
        "local Ollama: set #{key_variable(options.model)}, or choose a model with " <>
        "--model PROVIDER:MODEL (#{program} help models lists them)"
    end
  end

  def missing_key_message(%Options{model: model}, program) do
    "no API key for #{ModelSpec.provider(model)}: set #{key_variable(model)}, " <>
      "or choose another model with --model PROVIDER:MODEL (#{program} help models)"
  end

  defp key_variable(model), do: env_variable(ModelSpec.provider(model)) || "its API key"

  @doc """
  What the terminal UI's first-run panel (`Lemieux.TUI.FirstRun`) needs,
  when the model it would start on has no key; `nil` when it has one.

    * `:providers` — `recommended/0`'s rows, each with its `:credential`
      (a row whose key is already set needs none pasted), then, when the
      local daemon serves a model that can call tools, a `Local (Ollama)`
      row that needs no key (`key?: false`). The daemon is asked again
      here, as the panel is about to open, rather than trusting the probe
      `local/2` made at startup: under load that one can miss a running
      daemon, and a person shown only paid providers had no way to learn of
      the free one. When a person chose the model (see `:selected`), its
      provider's row carries that model rather than the table's, marked
      `own?: true`, and is added at the top when the table has no row for
      the provider: saving a key pasted there keeps the model and the
      session as they are.
    * `:hint` — a sentence for under the list: the context-window caveat
      with every way to a local model, whether one is offered or not.
    * `:selected` — the provider to preselect: the one a person named with
      the model, or the one a resumed session's transcript recorded (`lmx
      --resume ID`, `lmx -c`), or `nil` when nobody chose (step 4), so the
      panel steers a newcomer to no vendor. A resumed session runs on its
      transcript's model, but `model_source` still says what chose the
      start model before the transcript replaced it — a guess, when nothing
      was named — and read alone it opened the panel on no row, with the
      newcomer's sentence, for a model somebody had chosen when that session
      began.
    * `:intro` — the panel's first sentence when the panel's own ("no model
      credentials were found") would be false: for a model the person
      named or resumed, which other keys may be set beside, and under
      `--config none`, which looks at no keys. `nil` otherwise.
    * `:config_path` — where `Lemieux.CLI.Config.put_provider_key/3` and
      `put_model/2` should write, or `nil` when there is no file, when the
      panel can only say which variable to set.

  A hermetic run asks no daemon; its hint says how to name a local model.
  `opts` is as for `resolve/2` and `local/2`.
  """
  @spec first_run(options :: Options.t(), opts :: keyword()) :: map() | nil
  def first_run(%Options{} = options, opts \\ []) do
    provider = ModelSpec.provider(options.model)

    if credential(provider, options.config, opts) == :missing do
      {local, hint} = local_offer(options, opts)

      rows =
        Enum.map(recommended(), fn recommendation ->
          Map.merge(recommendation, %{
            id: recommendation.provider,
            credential: credential(recommendation.provider, options.config, opts)
          })
        end)

      {rows, selected} =
        if person_chose?(options), do: own_row(rows, options, provider), else: {rows, nil}

      %{
        config_path: Config.path(options.config),
        model: options.model,
        provider: provider,
        selected: selected,
        intro: intro(options, selected),
        hint: hint,
        providers: rows ++ local
      }
    end
  end

  # The row for a model the person chose carries that model, marked `own?`,
  # so pasting its key saves the key and nothing else
  # (`Lemieux.TUI.FirstRun`). The row used to carry the table's model, and
  # the save switched the session to it and wrote it over the person's
  # `"model"` in the config file: someone who named `openai:gpt-4.1-mini`
  # pasted a key and was moved to another, pricier model for good, and a
  # resumed session was moved off its transcript's. A provider the table
  # has no row for (`groq`) gets one, or the panel preselected nothing and
  # still said "Paste one"; one with no key variable to name gets neither
  # a row nor a selection.
  defp own_row(rows, options, provider) do
    own = %{model: options.model, own?: true}

    cond do
      Enum.any?(rows, &(&1.id == provider)) ->
        {Enum.map(rows, &if(&1.id == provider, do: Map.merge(&1, own), else: &1)), provider}

      env = env_variable(provider) ->
        row =
          Map.merge(own, %{
            id: provider,
            provider: provider,
            label: provider,
            env: env,
            credential: :missing
          })

        {[row | rows], provider}

      true ->
        {rows, nil}
    end
  end

  defp intro(options, nil) do
    if choosing?(options),
      do: nil,
      else:
        "--config none starts on #{options.model} and picks no model from your keys or a " <>
          "local Ollama. Choose a provider for this sitting (requests are billed by that " <>
          "provider), or Esc to look around first."
  end

  defp intro(options, _selected) do
    "No API key was found for #{options.model}. Paste one (requests are billed by that " <>
      "provider), choose another provider, or Esc to look around first."
  end

  # Whether a person chose the model the session runs on: named it, had it
  # remembered, or resumed a session, whose transcript's model was chosen
  # when it began; see `:selected` in `first_run/2`.
  defp person_chose?(%Options{resume: resume}) when is_binary(resume), do: true
  defp person_chose?(%Options{host: %{model_source: source}}), do: source not in @guessed

  # Under `--config none` the daemon is not asked, so no row is offered;
  # `/provider ollama` is the person naming the provider, which asks it.
  # Not `/model ollama:TAG`: `/model` chooses within the current provider,
  # so on the placeholder it asked for `anthropic:ollama:TAG`, and a
  # keyless sitting refused that with the same missing key.
  defp local_offer(options, opts) do
    if choosing?(options),
      do: options |> Ollama.local_model(ollama_opts(options, opts)) |> local_offer(),
      else:
        {[],
         "No key? Ollama runs models on this machine: /provider ollama switches to one " <>
           "it serves; #{@local_window} for the Ollama server."}
  end

  defp local_offer({:ok, served}) do
    {[
       %{
         id: "ollama",
         provider: "ollama",
         label: "Local (Ollama)",
         model: served.model,
         env: nil,
         key?: false,
         credential: :not_required,
         context_length: served.context_length,
         note: "no key needed · #{@local_window} for the Ollama server"
       }
     ],
     "Local (Ollama) runs on this machine with no key; #{@local_window} " <>
       "for the Ollama server, or long sessions silently lose their task."}
  end

  # The hint followed just before a first local session: after the pull and
  # the restart, `local/2` starts on the model with no panel in between, so
  # this is the last place to say what the window needs.
  defp local_offer({:error, :none}) do
    {[],
     "Ollama is running, but none of its models can call tools: pull one that can " <>
       "(ollama pull NAME; ollama.com/search?c=tools lists them), then restart lmx; " <>
       "#{@local_window} for the Ollama server."}
  end

  defp local_offer({:error, :unreachable}) do
    {[],
     "No key? lmx also runs local models with Ollama: start it, pull a model that can " <>
       "call tools (ollama pull NAME), and restart lmx; #{@local_window} for the Ollama server."}
  end

  # Whether this module may choose for the person: everything but a
  # hermetic run (see the module documentation).
  defp choosing?(%Options{host: %{state_dir: dir}}) when is_binary(dir), do: true
  defp choosing?(%Options{config: config}), do: Config.personal?(config)

  defp source(options, source), do: put_in(options.host.model_source, source)

  defp local_model(options, served), do: put_in(options.host[:local_model], served)

  defp reachable?(model, config, opts) do
    credential(ModelSpec.provider(model), config, opts) in [:present, :not_required]
  end

  defp first_available(config, opts) do
    Enum.find(@recommended, &(credential(&1.provider, config, opts) == :present))
  end

  defp known_provider(name) do
    Enum.find(ReqLLM.Providers.list(), &(Atom.to_string(&1) == name))
  end

  defp env_variable(provider) do
    case known_provider(provider) do
      nil -> nil
      atom -> ReqLLM.Keys.env_var_name(atom)
    end
  end

  defp getenv(name, opts) do
    case Keyword.fetch(opts, :env) do
      {:ok, env} -> Map.get(env, name)
      :error -> System.get_env(name)
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end

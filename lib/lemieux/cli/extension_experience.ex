defmodule Lemieux.CLI.ExtensionExperience do
  @moduledoc """
  Turns `--extension-profile`, `--build-ext` and a host's `:extension_profile`
  into the `Lemieux.Extension.Profile` the runtime applies.

  A portable profile is an explicit configuration choice. Combining it with
  flags that rewrite the model, prompt or tools would silently stop exercising
  that profile, so those combinations fail before a session is started.
  Runtime routes, credentials, stores and hooks remain host-owned.

  What leaves here is one extension, `profile: {Lemieux.Extension.Profile, opts}`
  in the host's `opts`, which `Lemieux.CLI.Runtime` applies before the catalog
  extensions so `ask_user` and the scout join the profile's tools rather than
  replacing them — the same profile opens the TUI and a headless
  run. The model is host authority and goes on the options, not the harness.
  The workspace is the bare directory: a profile does not silently acquire
  repository instructions, skills or plugins.
  """

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Routes
  alias Lemieux.CLI.Runtime
  alias Lemieux.Extension.Profile
  alias Lemieux.Extensions.Delegation
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Learning.Builder
  alias Lemieux.ModelSpec
  alias Lemieux.Provider

  @doc "Resolves builder or file tuning into the profile extension a host applies."
  @spec prepare(options :: Options.t(), opts :: keyword()) ::
          {:ok, Options.t(), keyword()} | {:error, String.t()}
  def prepare(options, opts) do
    if options.build_ext or options.extension_profile != nil or options.quota or
         Keyword.has_key?(opts, :extension_profile) do
      prepare_extension(options, opts)
    else
      {:ok, options, opts}
    end
  end

  defp prepare_extension(options, opts) do
    with :ok <- profile_choice(options, opts),
         :ok <- compatible(options, opts),
         provider = provider(options, opts),
         {:ok, profile} <- selected_profile(options, provider, opts),
         extension = extension(profile, provider, designation(options, opts), opts),
         # Validated now, so a profile that cannot open says so here rather
         # than when the session starts.
         {:ok, _state} <- Profile.init(elem(extension, 1)) do
      cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)

      welcome =
        if options.build_ext,
          do:
            "Extension builder · harness tuning\nModel: #{profile["model"]} · effort: #{profile["options"]["reasoning_effort"]}\nWhat job should your extension do, and what would a good result look like?\n#{limit(profile)} Benchmark limits are set separately.",
          else: nil

      opts =
        Keyword.merge(opts,
          provider: provider,
          profile: extension,
          workspace: %Discovery{root: cwd},
          welcome: welcome
        )

      {:ok, %{options | model: Profile.model(profile)}, opts}
    else
      {:error, {:unpriced_builder_model, model}} ->
        {:error,
         "#{model} cannot be priced before routing, and the builder's $5 cap needs a priced " <>
           "estimate. Use the normal TUI's /create-extension skill, or use --build-ext --quota " <>
           "for authorized quota traffic."}

      {:error, reason} ->
        {:error, "Cannot open extension experience: #{inspect(reason)}"}
    end
  end

  # The host's connection, with the routes the host registered when it did
  # so before coming here (`Lemieux.CLI.Runtime.with_routes/2`), else the
  # shipped ones alone.
  defp provider(options, opts) do
    Keyword.get_lazy(opts, :provider, fn ->
      Runtime.provider(
        options,
        Keyword.get_lazy(opts, :routes, fn -> Routes.builtin(options) end)
      )
    end)
  end

  defp extension(profile, provider, name, opts) do
    {Profile,
     [profile: profile, provider: provider, name: name] ++ Keyword.take(opts, [:tool_registry])}
  end

  defp designation(%Options{build_ext: true}, _opts), do: "Lemieux.Learning.Builder"

  defp designation(options, opts),
    do: options.extension_profile || Keyword.get(opts, :extension_name, "compiled extension")

  defp selected_profile(options, provider, opts) do
    case Keyword.fetch(opts, :extension_profile) do
      {:ok, profile} ->
        {:ok, profile}

      :error ->
        if options.build_ext,
          do: selected(options, provider),
          else: Profile.read(options.extension_profile, opts)
    end
  end

  defp selected(%Options{build_ext: true} = options, provider) do
    models = Provider.available_models(provider)
    explicit? = Keyword.has_key?(options.given, :model) or Options.env("LMX_MODEL") != nil

    model =
      if explicit? or options.model in models or models == [],
        do: options.model,
        else:
          Enum.find(
            models,
            hd(models),
            &(ModelSpec.provider(&1) == ModelSpec.provider(options.model))
          )

    builder_profile(model, options.quota, provider)
  end

  # A metered builder session needs a priced estimate for its $5 cap, and a
  # route that cannot price its requests — Ixway, a relay to a server of
  # one's own — would have every request refused. Asked of the provider, not
  # guessed from the name, as the scout does (`Lemieux.Extensions.Delegation`).
  defp builder_profile(model, true, _provider), do: {:ok, Builder.profile(model, quota: true)}

  defp builder_profile(model, false, provider) do
    if Delegation.priced?(provider, model),
      do: {:ok, Builder.profile(model, quota: false)},
      else: {:error, {:unpriced_builder_model, model}}
  end

  defp limit(%{"options" => %{"usage_mode" => "quota", "max_requests" => maximum}}),
    do:
      "Quota-backed session: at most #{maximum} direct model requests; remaining provider quota is unknown."

  defp limit(_profile), do: "Builder session cap: $5."

  defp profile_choice(options, opts) do
    supplied? = Keyword.has_key?(opts, :extension_profile)

    cond do
      supplied? and (options.build_ext or options.extension_profile != nil) ->
        {:error, :choose_one_extension_profile}

      options.build_ext and options.extension_profile != nil ->
        {:error, :choose_builder_or_profile}

      true ->
        :ok
    end
  end

  defp compatible(%Options{quota: true, build_ext: false}, _opts),
    do: {:error, :quota_flag_requires_builder}

  defp compatible(options, opts) do
    supplied? = Keyword.has_key?(opts, :extension_profile)

    flags = [
      :system,
      :elixir,
      :delegate,
      :mcp_config,
      :skill_dir,
      :plugin_dir,
      :marketplace,
      :plugin
    ]

    flags = if options.extension_profile || supplied?, do: [:model | flags], else: flags

    cond do
      options.resume != nil ->
        {:error, :resume_without_profile_flags}

      ((options.web_search != nil or options.web_fetch) and
         not Options.automatic_web?(options)) or
          Enum.any?(flags, &Keyword.has_key?(options.given, &1)) ->
        {:error, :conflicting_profile_flags}

      true ->
        :ok
    end
  end
end

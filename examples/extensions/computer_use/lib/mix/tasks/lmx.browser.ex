defmodule Mix.Tasks.Lmx.Browser do
  @shortdoc "Run the experimental System One/Wallaby browser extension"
  @moduledoc """
  Run a task with `--url URL --goal TEXT --allow-host HOST`, or `--query TEXT`
  for explicit Exa search. `--demo` runs the local hotel fixture and verifies
  its outcome. `--env-file PATH` loads private credentials without printing
  them; `--text-model MODEL` selects a ReqLLM model for field text. Optional
  `--journal PATH` creates a new private JSONL file; never place it in Git.

  `--systemone-provider NAME` selects the System One provider that chooses
  each action: a name from `"systemone_providers"` in the lmx config file,
  `typesafe`, `ixway`, or `auto` (the default: Ixway when its endpoint and a
  model are set, TypeSafe when `JEV_API_KEY` or a saved TypeSafe key is). The
  config file is the one `lmx` reads (`LMX_CONFIG`, `none` for none). A
  provider that cannot be used stops the task before the browser starts,
  with the sentence saying what is missing; nothing falls back to another.

  `--fetch-only --url URL --allow-host HOST` fetches without inference. Add
  `--no-browser-fetch` for HTTP-only operation without browser startup.
  `--render-timeout-ms` bounds rendering; `--render-wait-ms` bounds settling.

  For browser operation, Chrome and ChromeDriver must be installed. Set LMX_BROWSER_CHROME and
  LMX_BROWSER_CHROMEDRIVER for nonstandard paths. This runtime is experimental
  and local; the host owns browser network isolation.
  """
  use Mix.Task

  alias Lemieux.CLI.{Config, Options, SystemOne}

  @impl Mix.Task
  def run(argv) do
    {args, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          url: :string,
          goal: :string,
          query: :string,
          allow_host: :keep,
          demo: :boolean,
          fetch_only: :boolean,
          browser_fetch: :boolean,
          env_file: :string,
          systemone_provider: :string,
          text_model: :string,
          journal: :string,
          max_steps: :integer,
          max_verification_retries: :integer,
          crawl_pages: :integer,
          timeout_ms: :integer,
          render_timeout_ms: :integer,
          render_wait_ms: :integer,
          expect_text: :string,
          expect_url: :string
        ]
      )

    if rest != [] or invalid != [],
      do: Mix.raise("Invalid browser arguments; use mix help lmx.browser")

    Mix.Task.run("app.start")
    load_env(args[:env_file])

    # After the env file, which may hold the provider's key; before the
    # browser, which a task without a classifier would start for nothing.
    args =
      if args[:fetch_only] do
        args
      else
        case system_one_provider(args[:systemone_provider]) do
          {:ok, provider} -> Keyword.put(args, :systemone, provider: provider)
          {:error, reason} -> Mix.raise(reason)
        end
      end

    if args[:fetch_only] == true and args[:browser_fetch] == false do
      execute(args)
    else
      case LemieuxComputerUse.Wallaby.start() do
        :ok -> execute(args)
        _ -> Mix.raise("Browser startup failed; check Chrome and ChromeDriver configuration")
      end
    end
  end

  @doc false
  @spec load_env(path :: Path.t() | nil) :: :ok
  def load_env(nil), do: :ok

  def load_env(path) do
    case Dotenvy.source([path, System.get_env()], require_files: true) do
      {:ok, values} -> System.put_env(values)
      _ -> Mix.raise("Could not load the requested environment file")
    end
  end

  @doc false
  # Resolves `--systemone-provider` against the lmx config file the way `lmx`
  # does (`Lemieux.CLI.SystemOne.provider/3`), then checks the provider can
  # be reached the way the classifier will build it. The benches use it too.
  @spec system_one_provider(selection :: String.t() | nil) ::
          {:ok, LemieuxComputerUse.SystemOne.provider()} | {:error, String.t()}
  def system_one_provider(selection) do
    with {:ok, config} <- lmx_config() do
      case SystemOne.provider(config, selection,
             ixway_endpoint: Options.env("LMX_IXWAY_URL"),
             selected_by: "--systemone-provider"
           ) do
        {:ok, provider} ->
          usable(provider)

        {:unavailable, reason} ->
          {:error, "The browser needs a System One provider, but #{reason}."}
      end
    end
  end

  # Blank counts as unset, as it does for lmx (`Lemieux.CLI.Options.env/1`).
  defp lmx_config do
    case Options.env("LMX_CONFIG") do
      "none" -> {:ok, nil}
      nil -> Config.load(Config.default_path(), optional: true)
      path -> Config.load(Path.expand(path), [])
    end
  end

  # A resolved provider's name matched an entry, so it is not a mistyped key
  # and can be named.
  defp usable(provider) do
    case LemieuxComputerUse.SystemOne.client(provider: provider) do
      {:ok, _client} ->
        {:ok, provider}

      {:error, _reason} ->
        {:error,
         "The #{provider.name} System One provider cannot be used: its base_url must be an " <>
           "http(s) root before /v1/systemone, without credentials, query or fragment, and " <>
           "it needs a model."}
    end
  end

  defp execute(args) do
    if args[:fetch_only], do: fetch_only(args), else: execute_task(args)
  end

  defp fetch_only(args) do
    opts =
      Keyword.take(args, [:browser_fetch, :render_timeout_ms, :render_wait_ms]) ++
        [allowed_hosts: Keyword.get_values(args, :allow_host)]

    with {:ok, opts} <- LemieuxComputerUse.validate(opts),
         url when is_binary(url) <- args[:url] do
      tool = LemieuxComputerUse.Fetch.new(Lemieux.Tools.WebFetch.new(), opts)

      receipt =
        Lemieux.Tools.run(
          [tool],
          [],
          %{id: "fetch", name: "web_fetch", arguments: %{"url" => url}},
          %{
            cwd: File.cwd!(),
            environment: Lemieux.Environment.local(),
            tool_output_bytes: 200_000
          }
        )

      Mix.shell().info(JSON.encode!(Map.take(receipt, [:output, :error?, :structured_content])))
      if receipt.error?, do: Mix.raise("Fetch failed")
    else
      _ -> Mix.raise("--fetch-only requires --url and --allow-host")
    end
  end

  defp execute_task(args) do
    if args[:demo] do
      {:ok, server, url} = LemieuxComputerUse.Fixture.start()

      try do
        run_task(%{"url" => url, "goal" => LemieuxComputerUse.Fixture.goal()}, args,
          allowed_hosts: ["127.0.0.1"],
          unsafe_allow_loopback_for_tests: true,
          fetch: Lemieux.Tools.WebFetch.new(unsafe_allow_loopback_for_tests: true),
          verify: &LemieuxComputerUse.Fixture.verified?/1
        )
      after
        LemieuxComputerUse.Fixture.stop(server)
      end
    else
      input =
        %{"goal" => args[:goal], "url" => args[:url], "query" => args[:query]}
        |> Map.reject(fn {_, v} -> is_nil(v) end)

      run_task(
        input,
        args,
        [allowed_hosts: Keyword.get_values(args, :allow_host)] ++ verification(args)
      )
    end
  end

  defp verification(args) do
    if args[:expect_text] || args[:expect_url] do
      [
        verify: fn page ->
          (is_nil(args[:expect_text]) || String.contains?(page["text"], args[:expect_text])) and
            (is_nil(args[:expect_url]) || page["url"] == args[:expect_url])
        end
      ]
    else
      []
    end
  end

  defp run_task(input, args, extra) do
    opts =
      Keyword.take(args, [
        :systemone,
        :text_model,
        :max_steps,
        :max_verification_retries,
        :crawl_pages,
        :timeout_ms,
        :browser_fetch,
        :render_timeout_ms,
        :render_wait_ms
      ]) ++ extra

    with_journal(args[:journal], fn emit ->
      {status, report} = LemieuxComputerUse.Runner.run(input, Keyword.put(opts, :on_event, emit))
      Mix.shell().info(JSON.encode!(report))
      if status == :error, do: Mix.raise("Browser task stopped: #{report["status"]}")
    end)
  end

  defp with_journal(nil, fun), do: fun.(fn _ -> :ok end)

  defp with_journal(path, fun) do
    # Exclusive creation refuses accidental trace overwrites and symlinks.
    {:ok, file} = File.open(path, [:write, :exclusive, :binary])
    :ok = File.chmod(path, 0o600)

    try do
      fun.(fn event ->
        IO.binwrite(file, JSON.encode!(event) <> "\n")
        :file.sync(file)
      end)
    after
      File.close(file)
    end
  end
end

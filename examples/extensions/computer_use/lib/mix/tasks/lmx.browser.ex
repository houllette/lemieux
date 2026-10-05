defmodule Mix.Tasks.Lmx.Browser do
  @shortdoc "Run the experimental Jev/Wallaby browser extension"
  @moduledoc """
  Run a task with `--url URL --goal TEXT --allow-host HOST`, or `--query TEXT`
  for explicit Exa search. `--demo` runs the local hotel fixture and verifies
  its outcome. `--env-file PATH` loads private credentials without printing
  them; `--text-model MODEL` selects a ReqLLM model for field text. Optional
  `--journal PATH` creates a new private JSONL file; never place it in Git.

  `--fetch-only --url URL --allow-host HOST` fetches without inference. Add
  `--no-browser-fetch` for HTTP-only operation without browser startup.
  `--render-timeout-ms` bounds rendering; `--render-wait-ms` bounds settling.

  For browser operation, Chrome and ChromeDriver must be installed. Set LMX_BROWSER_CHROME and
  LMX_BROWSER_CHROMEDRIVER for nonstandard paths. This runtime is experimental
  and local; the host owns browser network isolation.
  """
  use Mix.Task

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

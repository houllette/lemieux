defmodule Lemieux.Extensions.Workspace.Plugin.Remote do
  @moduledoc false

  # Fetching marketplace catalogs and the plugins they name, into the user
  # cache, keyed by source and revision.
  #
  # Two kinds of checkout, because a pin and a branch promise different things:
  #
  #   * A pinned plugin (`sha`) names exactly one revision. A cached checkout
  #     of it is the checkout, however old, so a pinned plugin costs no network
  #     after the first fetch. Its `ref` is only where the shallow clone starts:
  #     the pinned commit is then fetched and checked out, as Claude Code does.
  #     Verifying the branch tip against the pin instead refused every entry
  #     whose branch had moved on — most of a large catalog's pinned entries on
  #     any given day.
  #   * A catalog, or a plugin with no pin, means "whatever its branch says
  #     now". The revision last fetched is remembered per source, reused for
  #     `:refresh_after_ms` (an hour by default) and fetched again after that.
  #     A refresh that fails — offline, a proxy, a host that is down — falls
  #     back to the remembered copy with a diagnostic, rather than costing the
  #     person their session: re-cloning on every start made every offline
  #     `lmx` fail while a perfectly good copy sat in the cache. A catalog
  #     named by a direct `marketplace.json` URL is remembered the same way,
  #     as the body last fetched.
  #
  # A pinned entry's `ref` is only where the clone starts. A clone of a
  # branch that has since been deleted is tried again from the default
  # branch, and the pin is fetched by its id from there.

  @manifest_limit 2_000_000
  @github ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:@[^\s]+)?$/
  @scp_git ~r/^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+:[^\s]+$/
  @sha ~r/^[0-9a-fA-F]{40}$/
  @refresh_after_ms :timer.hours(1)

  @type fetched_manifest :: %{
          contents: String.t(),
          path: String.t(),
          root: Path.t() | nil,
          diagnostics: [String.t()]
        }

  @spec marketplace(source :: String.t(), opts :: keyword()) ::
          {:ok, fetched_manifest()} | {:error, String.t()}
  def marketplace(source, opts \\ []) when is_binary(source) and is_list(opts) do
    cond do
      local?(source) -> local_manifest(source)
      direct_manifest_url?(source) -> remote_manifest(source, opts)
      git_source?(source) -> git_marketplace(source, opts)
      true -> local_manifest(source)
    end
  end

  @doc """
  Materializes one remote plugin source, returning its root and anything worth
  telling the person about how it was obtained (a cached copy used because a
  refresh failed).
  """
  @spec plugin(source :: term(), opts :: keyword()) ::
          {:ok, Path.t(), [String.t()]} | {:error, String.t()}
  def plugin(%{"source" => "github", "repo" => repo} = source, opts)
      when is_binary(repo) do
    with {:ok, repo} <- github_repo(repo) do
      materialize("https://github.com/#{repo}.git", source, opts)
    end
  end

  def plugin(%{"source" => "url", "url" => url} = source, opts) when is_binary(url) do
    with {:ok, git_url} <- git_url(url) do
      materialize(git_url, source, opts)
    end
  end

  def plugin(%{"source" => "git-subdir", "url" => url, "path" => path} = source, opts)
      when is_binary(url) and is_binary(path) do
    with :ok <- safe_subdirectory(path),
         {:ok, git_url} <- git_url(url),
         {:ok, root, diagnostics} <- materialize(git_url, source, opts),
         {:ok, relative} <- safe_relative(path, root) do
      {:ok, Path.join(root, relative), diagnostics}
    else
      {:error, _reason} = error -> error
    end
  end

  def plugin(%{"source" => kind}, _opts) when is_binary(kind) do
    {:error,
     "remote plugin source #{kind} is not supported by lmx; use github, url, or git-subdir"}
  end

  def plugin(source, _opts),
    do: {:error, "remote plugin has an invalid source: #{inspect(source)}"}

  @doc """
  Where remote checkouts are cached when the caller names no `:cache_dir`: the
  platform's per-user cache directory for `lemieux`, under `plugins`.

  `:filename.basedir/2` answers in the type it was asked in — a binary here —
  and piping that into `List.to_string/1` crashed every remote marketplace with
  a `FunctionClauseError` before anything was fetched. The tests all passed a
  `:cache_dir`, so the default was the one path nothing exercised.
  """
  @spec default_cache_root() :: Path.t()
  def default_cache_root do
    :user_cache
    |> :filename.basedir("lemieux")
    |> to_string()
    |> Path.join("plugins")
  end

  defp local?(source), do: File.exists?(Path.expand(source))

  defp local_manifest(source) do
    path = source |> Path.expand() |> manifest_path()

    case File.read(path) do
      {:ok, contents} ->
        {:ok, %{contents: contents, path: path, root: marketplace_root(path), diagnostics: []}}

      {:error, reason} ->
        {:error, "could not read marketplace #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp remote_manifest(url, opts) do
    record = record_path({:manifest, url}, opts)

    case remembered_manifest(record, opts) do
      {:fresh, contents, _fetched_at} -> {:ok, direct_manifest(url, contents, [])}
      remembered -> fetch_manifest(url, record, remembered, opts)
    end
  end

  defp fetch_manifest(url, record, remembered, opts) do
    case get_manifest(url, opts) do
      {:ok, body} ->
        remember(record, %{"contents" => body})
        {:ok, direct_manifest(url, body, [])}

      {:error, reason} ->
        manifest_fall_back(remembered, url, reason)
    end
  end

  defp manifest_fall_back({:stale, contents, fetched_at}, url, reason),
    do: {:ok, direct_manifest(url, contents, [stale_notice(url, reason, fetched_at)])}

  defp manifest_fall_back(:none, _url, reason), do: {:error, reason}

  defp direct_manifest(url, contents, diagnostics),
    do: %{contents: contents, path: url, root: nil, diagnostics: diagnostics}

  defp remembered_manifest(record, opts) do
    with {:ok, %{"contents" => contents, "fetched_at" => fetched_at}} when is_binary(contents) <-
           read_record(record),
         {:ok, freshness} <- freshness(fetched_at, opts) do
      {freshness, contents, fetched_at}
    else
      _missing_or_unreadable -> :none
    end
  end

  defp get_manifest(url, opts) do
    get = Keyword.get(opts, :get, &default_get/1)

    case get.(url) do
      {:ok, status, body} when status in 200..299 and is_binary(body) ->
        if byte_size(body) <= @manifest_limit,
          do: {:ok, body},
          else: {:error, "marketplace #{url} is larger than #{@manifest_limit} bytes"}

      {:ok, status, _body} ->
        {:error, "could not fetch marketplace #{url}: HTTP #{status}"}

      {:error, reason} ->
        {:error, "could not fetch marketplace #{url}: #{inspect(reason)}"}

      other ->
        {:error, "marketplace fetcher returned an invalid result: #{inspect(other)}"}
    end
  end

  defp default_get(url) do
    case Req.get(url,
           decode_body: false,
           redirect: true,
           max_redirects: 5,
           connect_options: [timeout: 5_000],
           receive_timeout: 15_000,
           retry: false
         ) do
      {:ok, response} -> {:ok, response.status, IO.iodata_to_binary(response.body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_marketplace(source, opts) do
    {url, ref} = marketplace_git(source)

    with {:ok, root, diagnostics} <- materialize(url, %{"ref" => ref}, opts),
         path = manifest_path(root),
         {:ok, contents} <- read_materialized(path) do
      {:ok,
       %{
         contents: contents,
         path: "#{source}:.claude-plugin/marketplace.json",
         root: root,
         diagnostics: diagnostics
       }}
    end
  end

  defp read_materialized(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error, "could not read marketplace #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp materialize(url, source, opts) do
    ref = optional_string(source, "ref")
    sha = optional_string(source, "sha")

    with :ok <- valid_sha(sha) do
      if sha, do: pinned(url, ref, String.downcase(sha), opts), else: unpinned(url, ref, opts)
    end
  end

  defp pinned(url, ref, sha, opts) do
    destination = cache_path(url, sha, opts)

    if File.dir?(destination) do
      {:ok, destination, []}
    else
      with {:ok, root, _revision} <- fetch_checkout(url, ref, sha, opts), do: {:ok, root, []}
    end
  end

  defp unpinned(url, ref, opts) do
    record = record_path({:git, url, ref}, opts)
    refresh(remembered(record, url, opts), record, url, ref, opts)
  end

  defp refresh({:fresh, root, _fetched_at}, _record, _url, _ref, _opts), do: {:ok, root, []}

  defp refresh(remembered, record, url, ref, opts) do
    case fetch_checkout(url, ref, nil, opts) do
      {:ok, root, revision} ->
        remember(record, %{"revision" => revision})
        {:ok, root, []}

      {:error, reason} ->
        fall_back(remembered, url, reason)
    end
  end

  defp fall_back({:stale, root, fetched_at}, url, reason),
    do: {:ok, root, [stale_notice(url, reason, fetched_at)]}

  defp fall_back(:none, _url, reason), do: {:error, reason}

  defp stale_notice(url, reason, fetched_at) do
    fetched = fetched_at |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second)

    "#{redact(url)} could not be refreshed (#{reason}); using the copy fetched " <>
      DateTime.to_iso8601(fetched)
  end

  # What was fetched last for one unpinned source, and when. Only the revision
  # is kept: the checkout's place follows from it, so a record cannot point
  # anywhere but into this cache.
  defp remembered(record, url, opts) do
    with {:ok, %{"revision" => revision, "fetched_at" => fetched_at}} when is_binary(revision) <-
           read_record(record),
         true <- Regex.match?(@sha, revision),
         root = cache_path(url, revision, opts),
         true <- File.dir?(root),
         {:ok, freshness} <- freshness(fetched_at, opts) do
      {freshness, root, fetched_at}
    else
      _missing_or_unreadable -> :none
    end
  end

  defp read_record(record) do
    with {:ok, bytes} <- File.read(record), do: JSON.decode(bytes)
  end

  defp freshness(fetched_at, opts) when is_integer(fetched_at) do
    age = System.os_time(:millisecond) - fetched_at
    fresh? = age >= 0 and age < Keyword.get(opts, :refresh_after_ms, @refresh_after_ms)
    {:ok, if(fresh?, do: :fresh, else: :stale)}
  end

  defp freshness(_fetched_at, _opts), do: :error

  # Written beside and renamed over, so two sessions starting at once never
  # read half a record. Losing the record costs a refetch, nothing more, so a
  # failure to write it is not a failure to load the plugin.
  defp remember(record, fields) do
    temporary = "#{record}.#{System.unique_integer([:positive])}.tmp"

    contents =
      fields |> Map.put("fetched_at", System.os_time(:millisecond)) |> JSON.encode!()

    with :ok <- File.mkdir_p(Path.dirname(record)),
         :ok <- File.write(temporary, contents),
         :ok <- File.rename(temporary, record) do
      :ok
    else
      _error ->
        File.rm(temporary)
        :ok
    end
  end

  # One record per source: a git URL and the branch it follows, or a direct
  # catalog URL, which can never be mistaken for one.
  defp record_path({:git, url, ref}, opts), do: record_file("git\0#{url}\0#{ref}", opts)
  defp record_path({:manifest, url}, opts), do: record_file("manifest\0#{url}", opts)

  defp record_file(key, opts) do
    digest = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
    Path.join([cache_root(opts), "sources", digest <> ".json"])
  end

  defp fetch_checkout(url, ref, sha, opts) do
    with {:ok, temporary} <- temporary_checkout(opts) do
      result = materialize_checkout(temporary, url, ref, sha, opts)

      if match?({:error, _reason}, result), do: File.rm_rf(temporary)
      result
    end
  end

  defp materialize_checkout(temporary, url, ref, sha, opts) do
    with :ok <- clone_from(url, ref, sha, temporary, opts),
         :ok <- checkout_pin(temporary, sha, opts),
         {:ok, revision} <- revision(temporary, opts),
         :ok <- matches_sha(revision, sha),
         {:ok, destination} <- cache(temporary, url, revision, opts) do
      {:ok, destination, revision}
    end
  end

  defp temporary_checkout(opts) do
    root = cache_root(opts)
    token = System.unique_integer([:positive, :monotonic])
    temporary = Path.join(root, ".fetch-#{token}")

    case File.mkdir_p(root) do
      :ok ->
        {:ok, temporary}

      {:error, reason} ->
        {:error, "could not create plugin cache #{root}: #{:file.format_error(reason)}"}
    end
  end

  # A pin outlives the branch it was taken from: when cloning that branch
  # fails, the clone starts from the default branch and `checkout_pin/3`
  # fetches the commit by its id.
  defp clone_from(url, ref, sha, destination, opts) when is_binary(ref) and is_binary(sha) do
    with {:error, _no_such_branch} <- clone(url, ref, destination, opts) do
      File.rm_rf(destination)
      clone(url, nil, destination, opts)
    end
  end

  defp clone_from(url, ref, _sha, destination, opts), do: clone(url, ref, destination, opts)

  defp clone(url, ref, destination, opts) do
    args = ["clone", "--depth", "1"] ++ branch(ref) ++ ["--", url, destination]
    git(args, opts, "clone #{redact(url)}")
  end

  defp branch(nil), do: []
  defp branch(ref), do: ["--branch", ref]

  # The pin, whatever the branch did since. A clone whose tip already is the
  # pin needs nothing more; otherwise the one commit is fetched by its id.
  defp checkout_pin(_root, nil, _opts), do: :ok

  defp checkout_pin(root, sha, opts) do
    case revision(root, opts) do
      {:ok, revision} ->
        if String.downcase(revision) == sha, do: :ok, else: fetch_pin(root, sha, opts)

      {:error, _reason} ->
        fetch_pin(root, sha, opts)
    end
  end

  defp fetch_pin(root, sha, opts) do
    with :ok <-
           git(["-C", root, "fetch", "--depth", "1", "origin", sha], opts, "fetch pinned #{sha}") do
      git(["-C", root, "checkout", "--quiet", "--detach", sha], opts, "check out pinned #{sha}")
    end
  end

  defp revision(root, opts) do
    case git_result(["-C", root, "rev-parse", "HEAD"], opts) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, "git rev-parse failed (#{status}): #{String.trim(output)}"}
    end
  end

  defp cache(temporary, url, revision, opts) do
    destination = cache_path(url, revision, opts)

    if File.dir?(destination) do
      File.rm_rf(temporary)
      {:ok, destination}
    else
      case File.rename(temporary, destination) do
        :ok ->
          {:ok, destination}

        {:error, :eexist} ->
          File.rm_rf(temporary)
          {:ok, destination}

        {:error, reason} ->
          {:error, "could not cache remote plugin: #{:file.format_error(reason)}"}
      end
    end
  end

  defp cache_path(url, revision, opts) do
    digest =
      :crypto.hash(:sha256, url <> "\0" <> String.downcase(revision))
      |> Base.encode16(case: :lower)

    Path.join(cache_root(opts), digest)
  end

  defp cache_root(opts), do: Keyword.get_lazy(opts, :cache_dir, &default_cache_root/0)

  defp git(args, opts, action) do
    case git_result(args, opts) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, "could not #{action} (git exit #{status}): #{String.trim(output)}"}
    end
  end

  defp git_result(args, opts) do
    run = Keyword.get(opts, :git, &default_git/1)
    run.(args)
  rescue
    error -> {Exception.message(error), 1}
  end

  defp default_git(args),
    do: System.cmd("git", args, stderr_to_stdout: true, env: [{"GIT_TERMINAL_PROMPT", "0"}])

  defp valid_sha(nil), do: :ok

  defp valid_sha(sha),
    do: if(Regex.match?(@sha, sha), do: :ok, else: {:error, "invalid git sha: #{sha}"})

  defp matches_sha(_revision, nil), do: :ok

  defp matches_sha(revision, sha) do
    if String.downcase(revision) == sha,
      do: :ok,
      else: {:error, "remote plugin resolved to #{revision}, expected pinned sha #{sha}"}
  end

  defp safe_subdirectory(path) do
    expanded = Path.expand(path, "/")
    segments = Path.split(path)

    if Path.type(path) == :relative and expanded != "/" and ".." not in segments,
      do: :ok,
      else: {:error, "remote plugin has an unsafe subdirectory path: #{path}"}
  end

  defp safe_relative(path, root) do
    case Path.safe_relative(path, root) do
      {:ok, relative} -> {:ok, relative}
      :error -> {:error, "remote plugin path escapes its repository: #{path}"}
    end
  end

  defp github_repo(repo) do
    if Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, repo),
      do: {:ok, repo},
      else: {:error, "invalid GitHub repository: #{repo}"}
  end

  defp git_url(url) do
    cond do
      Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, url) ->
        {:ok, "https://github.com/#{url}.git"}

      String.starts_with?(url, ["http://", "https://", "ssh://", "git://", "file://"]) ->
        {:ok, url}

      Regex.match?(@scp_git, url) ->
        {:ok, url}

      true ->
        {:error, "invalid remote plugin git URL: #{inspect(url)}"}
    end
  end

  defp git_source?(source) do
    Regex.match?(@github, source) or String.starts_with?(source, ["git@", "ssh://", "file://"]) or
      (String.starts_with?(source, ["http://", "https://"]) and not direct_manifest_url?(source))
  end

  defp direct_manifest_url?(source) do
    String.starts_with?(source, ["http://", "https://"]) and
      source |> URI.parse() |> Map.get(:path, "") |> String.ends_with?(".json")
  end

  defp marketplace_git(source) do
    if Regex.match?(@github, source) do
      [repo, ref] = String.split(source, "@", parts: 2) |> pad()
      {"https://github.com/#{repo}.git", ref}
    else
      uri = URI.parse(source)
      {URI.to_string(%{uri | fragment: nil}), uri.fragment}
    end
  end

  defp pad([value]), do: [value, nil]
  defp pad(pair), do: pair

  defp manifest_path(path) do
    if File.dir?(path), do: Path.join([path, ".claude-plugin", "marketplace.json"]), else: path
  end

  defp marketplace_root(path), do: path |> Path.dirname() |> Path.dirname()

  defp optional_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp redact(url) do
    case URI.parse(url) do
      %URI{userinfo: nil} -> url
      uri -> URI.to_string(%{uri | userinfo: "[credentials]"})
    end
  end
end

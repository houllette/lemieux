defmodule Lemieux.CLI.Learning.CodexAuth do
  @moduledoc """
  Lends the local Codex sign-in to an `openai_codex:` run, read-only.

  `req_llm`'s `openai_codex` provider sends requests to the ChatGPT Codex
  backend with OAuth tokens it reads, on every request, from a file of its
  own shape (`{"openai-codex": {"access", "refresh", "expires",
  "accountId"}}`). When the access token has expired it refreshes it and
  rewrites that file. The Codex CLI keeps the same sign-in in
  `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`) in a different shape.

  Handing `req_llm` the refresh token would be wrong. OpenAI rotates refresh
  tokens on use, so the first refresh the bench made would leave Codex
  holding a spent token and sign it out. This module therefore copies only
  the access token, its expiry and the account id into a private file under
  ignored `tmp/` and names that file to `req_llm`. Codex stays the only
  party that refreshes. A token that would expire within the run's margin
  stops the run before any task starts, instead of failing every task after
  it lapses; signing in to Codex again renews it.

  Nothing here enters a run configuration, a report or a transcript: the
  file is the only copy, it is mode `0600`, and `cleanup/1` removes it.
  """

  @default_dir "tmp/codex-auth"

  @typedoc "What a run may record about the credential: never the token."
  @type summary :: %{expires_at: DateTime.t(), source: Path.t()}

  @doc """
  Writes the derived credential file and points `req_llm` at it.

  ## Options

    * `:min_validity_hours` — the shortest remaining token lifetime a run
      accepts. Defaults to 24.
    * `:source` — the Codex `auth.json`. Defaults to `$CODEX_HOME/auth.json`,
      then `~/.codex/auth.json`.
    * `:path` — where the derived file goes. Defaults to one file per OS
      process under `#{@default_dir}/`, so a run finishing beside another
      cannot remove the file the other is still reading.
    * `:now` — the current time, for tests.
  """
  @spec prepare(opts :: keyword()) :: {:ok, Path.t(), summary()} | {:error, term()}
  def prepare(opts \\ []) do
    source = Keyword.get_lazy(opts, :source, &default_source/0)
    path = opts |> Keyword.get_lazy(:path, &default_path/0) |> Path.expand()
    min_hours = Keyword.get(opts, :min_validity_hours, 24)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, credential} <- read(source),
         :ok <- check_validity(credential.expires_at, now, min_hours),
         :ok <- write(path, credential) do
      Application.put_env(:req_llm, :oauth_file, path)
      {:ok, path, %{expires_at: credential.expires_at, source: source}}
    end
  end

  @doc "Removes the derived file and `req_llm`'s pointer to it."
  @spec cleanup(path :: Path.t()) :: :ok
  def cleanup(path) do
    if Application.get_env(:req_llm, :oauth_file) == path,
      do: Application.delete_env(:req_llm, :oauth_file)

    File.rm(path)
    :ok
  end

  defp default_path, do: Path.join(@default_dir, "oauth-#{System.pid()}.json")

  defp default_source do
    home = System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex")
    Path.join(home, "auth.json")
  end

  defp read(source) do
    with {:ok, body} <- File.read(source),
         {:ok, payload} <- JSON.decode(body),
         %{"tokens" => %{"access_token" => access} = tokens} when is_binary(access) <- payload,
         {:ok, claims} <- claims(access),
         exp when is_integer(exp) <- claims["exp"] do
      {:ok,
       %{
         access: access,
         account_id: tokens["account_id"] || get_in(claims, [auth_claim(), "chatgpt_account_id"]),
         expires_at: DateTime.from_unix!(exp)
       }}
    else
      {:error, :enoent} -> {:error, {:codex_not_signed_in, source}}
      {:error, reason} -> {:error, {:codex_auth_unreadable, source, reason}}
      _other -> {:error, {:codex_auth_unreadable, source, :no_chatgpt_access_token}}
    end
  end

  defp auth_claim, do: "https://api.openai.com/auth"

  # The expiry is read from the token's own claims. The signature is not
  # checked: the backend does that, and the bench only needs to know when to
  # stop trusting the copy.
  defp claims(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- JSON.decode(json) do
      {:ok, claims}
    else
      _malformed -> {:error, :access_token_not_a_jwt}
    end
  end

  defp check_validity(expires_at, now, min_hours) do
    remaining = DateTime.diff(expires_at, now, :second)

    if remaining >= min_hours * 3600,
      do: :ok,
      else: {:error, {:codex_token_expires_too_soon, expires_at, min_hours}}
  end

  # No `refresh` key, deliberately: see the moduledoc.
  defp write(path, credential) do
    entry =
      %{
        "type" => "oauth",
        "access" => credential.access,
        "expires" => DateTime.to_unix(credential.expires_at, :millisecond),
        "accountId" => credential.account_id
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(path, "", [:write]),
         :ok <- File.chmod(path, 0o600) do
      File.write(path, JSON.encode!(%{"openai-codex" => entry}))
    end
  end
end

defmodule Lemieux.Environment.Credentials do
  @moduledoc """
  Which of this process's environment variables a spawned command may see.

  Every command a session starts — the model's `bash`, a background task, the
  Elixir evaluation node, a command hook, an MCP stdio server — inherits the
  operating-system environment of the VM that started it (as the host
  corrected it, `Lemieux.Environment.Inherited`, for all but the evaluation
  node). That environment is where provider keys live: the quickstart tells a person to
  `export OPENAI_API_KEY`, and `req_llm` loads `.env` into it. Inherited
  unchanged, a single injected `curl -d "$OPENAI_API_KEY" …` in a README the
  model was asked to read spends somebody else's money.

  A policy says what to withhold:

    * `:inherit` — pass the environment through untouched. The library's
      default, because a host that embeds Lemieux in a CI job which *means* to
      hand `GITHUB_TOKEN` to its commands must not find it silently missing.
    * `{:scrub, allow}` — withhold every variable whose name contains `KEY`,
      `TOKEN`, `SECRET`, `PASSWORD` or `PASSWD` (case-insensitively), except
      those `allow` names. `lmx` runs this way. An allow entry is an exact
      name or a glob with `*` (`"GH_*"`, `"*_TOKEN"`), matched
      case-sensitively like the names themselves.

  The rule is deliberately a name pattern rather than a list of known
  providers. A list is always one provider behind — the next gateway's key is
  exactly the one nobody added — and the cost of withholding a variable that
  was not a credential (`KEYBOARD_LAYOUT`) is one allow entry, while the cost
  of passing one that was is the key.

  ## What a name heuristic cannot see

  It reads names, never values, so it is not an inventory of every secret a
  machine holds. A connection string with the password inside it
  (`DATABASE_URL=postgres://user:pass@host/db`), a variable that only points at
  a credential (`GOOGLE_APPLICATION_CREDENTIALS`, `KUBECONFIG`,
  `SSH_AUTH_SOCK`) and a secret under a name with none of the markers
  (`GITHUB_PAT`, `SLACK_WEBHOOK`, and `MYSQL_PWD`, the MySQL client's
  password) all pass. Some markers were left out on purpose because they are
  substrings of names every shell needs: `PAT` is in `PATH`, `PWD` is the
  working directory. What reads those values is a question for the sandbox
  (`Lemieux.Environment.Sandbox`, which hides the files they point at) or
  for an environment the host builds with only the variables it means to
  pass.

  `overrides/2` answers in the shape an Erlang port takes: `{name, false}`
  unsets `name` in the child. Runners that cannot unset a variable (ExCmd's
  helper appends to its own environment) blank it instead; see
  `Lemieux.Environment.Local.ExCmd`.
  """

  @typedoc """
  What a spawned command may inherit: `:inherit` passes everything,
  `{:scrub, allow}` withholds credential-shaped names not in `allow`.
  """
  @type policy :: :inherit | {:scrub, allow :: [String.t()]}

  # Substrings, matched against the upcased name. KEY catches API_KEY,
  # ACCESS_KEY_ID and PRIVATE_KEY; TOKEN catches GH_TOKEN and
  # *_SESSION_TOKEN; SECRET catches CLIENT_SECRET and AWS_SECRET_ACCESS_KEY;
  # PASSWORD and PASSWD catch DB_PASSWORD, PGPASSWORD and MYSQL_PASSWD, the
  # names database clients read a password from. Neither is a substring of
  # the other, so both are listed.
  @markers ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD"]

  @doc """
  Normalises a policy given in any of the accepted spellings.

  Accepts the two canonical forms, plus `true`/`false` and `nil` for
  configuration files and keyword options that have no way to spell a tuple:
  `true` scrubs with an empty allowlist, `false` and `nil` inherit. Anything
  else is an error rather than a guess, because a mistyped policy that fell
  back to `:inherit` would be the unsafe direction.
  """
  @spec policy(value :: term()) :: {:ok, policy()} | {:error, String.t()}
  def policy(:inherit), do: {:ok, :inherit}
  def policy(nil), do: {:ok, :inherit}
  def policy(false), do: {:ok, :inherit}
  def policy(true), do: {:ok, {:scrub, []}}

  def policy({:scrub, allow}) when is_list(allow) do
    if Enum.all?(allow, &is_binary/1),
      do: {:ok, {:scrub, allow}},
      else: {:error, "credential allow entries must be strings"}
  end

  def policy(other),
    do: {:error, "expected :inherit or {:scrub, allow}, got: #{inspect(other)}"}

  @doc """
  Whether `policy` withholds a variable called `name`.

  True when the policy scrubs, the name contains `KEY`, `TOKEN`, `SECRET`,
  `PASSWORD` or `PASSWD` in any case, and no allow entry matches it.
  """
  @spec sensitive?(name :: String.t(), policy :: policy()) :: boolean()
  def sensitive?(name, :inherit) when is_binary(name), do: false

  def sensitive?(name, {:scrub, allow}) when is_binary(name) and is_list(allow),
    do: credential_shaped?(name) and not allowed?(name, allow)

  @doc """
  The variables in `env` that `policy` withholds, as port-style unsets.

  `env` defaults to the running VM's environment, which is what a spawned
  command would otherwise inherit. The list is sorted so that two calls over
  the same environment produce the same list — it ends up in command lines and
  tests compare it.
  """
  @spec overrides(policy :: policy(), env :: %{optional(String.t()) => String.t()}) ::
          [{String.t(), false}]
  def overrides(policy, env \\ System.get_env())

  def overrides(:inherit, env) when is_map(env), do: []

  def overrides({:scrub, _allow} = policy, env) when is_map(env) do
    env
    |> Map.keys()
    |> Enum.filter(&sensitive?(&1, policy))
    |> Enum.sort()
    |> Enum.map(&{&1, false})
  end

  defp credential_shaped?(name) do
    upcased = String.upcase(name)
    Enum.any?(@markers, &String.contains?(upcased, &1))
  end

  defp allowed?(name, allow), do: Enum.any?(allow, &matches?(name, &1))

  defp matches?(name, name), do: true

  defp matches?(name, pattern) do
    if String.contains?(pattern, "*"),
      do: Regex.match?(glob(pattern), name),
      else: false
  end

  defp glob(pattern) do
    source =
      pattern
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.compile!("\\A" <> source <> "\\z")
  end
end

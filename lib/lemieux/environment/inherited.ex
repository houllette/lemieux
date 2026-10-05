defmodule Lemieux.Environment.Inherited do
  @moduledoc """
  What the processes started on a person's behalf inherit — the commands a
  session runs, command hooks, MCP stdio servers, the editor the terminal UI
  opens — where the host says that is not this VM's own environment.

  A VM is not always started from the environment of the person using it.
  One started by a release script gets ERTS's `bin` directory and the
  release's own put first on `PATH` by `erlexec`, which also sets `BINDIR`,
  `ROOTDIR`, `EMU` and `PROGNAME`, and the release script adds `RELEASE_*`.
  The VM needs them. A person's command does not: inherited, they made the
  person's own `erl` — and through it `elixir`, `mix` and `iex` — resolve to
  the release's ERTS, which stops at once with `cannot get bootfile`, so an
  agent run from the installed `lmx` could not run an Elixir project's tests
  (found in the launch review, 2026-10).

  The library cannot tell which variables are the person's: only whatever
  started the VM knows what it added. So the host says, once, at boot —
  `put/1` with the variables to set and those to remove — and every place
  that starts a process for a person applies that first, then the session's
  credential policy (`Lemieux.Environment.Credentials`), then whatever the
  process is given explicitly. `lmx`'s launcher records the environment it
  was started with before anything changes it, and `lmx` hands the
  difference over here; a host that embeds Lemieux in a release of its own
  does the same, and one that starts its VM from the person's own shell
  needs nothing.

  Not the Elixir evaluation node (`Lemieux.Eval.Sandbox`): that is a second
  BEAM of this VM's own, which boots from the same ERTS and needs the VM's
  environment to find it.

  The changes are the VM's, held in `:persistent_term`: they describe how the
  VM was started, which every session in it shares, and they are read on
  every command.
  """

  alias Lemieux.Environment.Credentials

  @key {__MODULE__, :changes}

  @typedoc "Variables to set, by name, and `nil` for each one to remove."
  @type changes :: %{optional(String.t()) => String.t() | nil}

  @doc """
  Records how what processes inherit differs from this VM's environment.
  Replaces whatever was recorded before; `%{}` records no difference.

  Raises `ArgumentError` for a name that is empty or holds `=` or a NUL, or
  a value that is not a string or `nil` or holds a NUL: no operating system
  can pass one on, and a host that got one wrong should hear it at boot,
  not as a command that silently ran without it.
  """
  @spec put(changes :: changes()) :: :ok
  def put(changes) when is_map(changes) do
    Enum.each(changes, &valid!/1)
    :persistent_term.put(@key, changes)
  end

  defp valid!({name, value}) when is_binary(name) and (is_binary(value) or is_nil(value)) do
    cond do
      name == "" or String.contains?(name, ["=", <<0>>]) ->
        raise ArgumentError, "not an environment variable name: #{inspect(name)}"

      is_binary(value) and String.contains?(value, <<0>>) ->
        raise ArgumentError, "the value of #{name} holds a NUL byte"

      true ->
        :ok
    end
  end

  defp valid!(other),
    do: raise(ArgumentError, "expected a {name, value | nil} pair, got: #{inspect(other)}")

  @doc "What `put/1` recorded, `%{}` when nothing was."
  @spec get() :: changes()
  def get, do: :persistent_term.get(@key, %{})

  @doc """
  What a process started for a person gets on top of this VM's environment
  `env`, in the shape an Erlang port takes: `{name, value}` to set, `{name,
  false}` to remove.

  The host's `changes` first; then every variable `policy` withholds from
  the environment those leave, removed. A variable the changes restore and
  the policy withholds is removed: the policy is about the process, not about
  where its environment came from. Sorted by name, so two calls over the
  same environment agree.
  """
  @spec overrides(
          policy :: Credentials.policy(),
          env :: %{optional(String.t()) => String.t()},
          changes :: changes()
        ) :: [{String.t(), String.t() | false}]
  def overrides(policy, env \\ System.get_env(), changes \\ get()) do
    withheld = Credentials.overrides(policy, apply_changes(env, changes))
    removed = MapSet.new(withheld, fn {name, false} -> name end)

    restored =
      Enum.flat_map(changes, fn
        {name, nil} -> if Map.has_key?(env, name), do: [{name, false}], else: []
        {name, value} -> if Map.get(env, name) == value, do: [], else: [{name, value}]
      end)
      |> Enum.reject(fn {name, _value} -> MapSet.member?(removed, name) end)

    Enum.sort_by(restored ++ withheld, &elem(&1, 0))
  end

  @doc """
  `overrides/3` in the shape `System.cmd/3`'s `:env` takes: `nil` removes.
  """
  @spec cmd_env(policy :: Credentials.policy()) :: [{String.t(), String.t() | nil}]
  def cmd_env(policy \\ :inherit) do
    Enum.map(overrides(policy), fn
      {name, false} -> {name, nil}
      pair -> pair
    end)
  end

  defp apply_changes(env, changes) do
    Enum.reduce(changes, env, fn
      {name, nil}, env -> Map.delete(env, name)
      {name, value}, env -> Map.put(env, name, value)
    end)
  end

  @doc """
  Finds `program` as a process started for a person would: on the `PATH`
  they inherit, not this VM's. A host that starts an MCP
  server named `erl` must start the person's `erl`, not the one first on the
  release's `PATH`. A name with a directory in it is looked up as
  `System.find_executable/1` looks it up.
  """
  @spec find_executable(program :: String.t()) :: Path.t() | nil
  def find_executable(program) when is_binary(program) do
    case Map.fetch(get(), path_name()) do
      {:ok, path} when is_binary(path) and program != "" ->
        if String.contains?(program, ["/", "\\"]),
          do: System.find_executable(program),
          else: on_path(program, path)

      _unchanged ->
        System.find_executable(program)
    end
  end

  defp on_path(program, path) do
    case :os.find_executable(String.to_charlist(program), String.to_charlist(path)) do
      false -> nil
      found -> List.to_string(found)
    end
  end

  # Windows keeps `Path`, and looks names up whatever their letter case.
  defp path_name do
    Enum.find(Map.keys(get()), "PATH", &(String.upcase(&1) == "PATH"))
  end
end

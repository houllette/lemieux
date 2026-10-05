# Fails when two Mix lockfiles resolve a dependency they share differently.
#
#     elixir scripts/check_lock_drift.exs [--allow NAME,...] mix.lock dist/lmx/mix.lock
#
# The standalone `lmx` release is a separate Mix project with its own lock, so
# a dependency bump at the root does not reach the binary people install. The
# two drifted without anyone noticing: the root had moved to jsv 0.23.1 and
# texture 2.0.0 while the release still shipped jsv 0.21.2 and texture 1.2.1.
# The library's tests ran against one set and the shipped executable against
# another. Dependencies only one project uses are not drift and are ignored.
#
# `--allow` names drift a person has reviewed and cannot remove yet, so the
# check still catches everything else. An allowed name that no longer drifts
# is reported, so the exception is deleted rather than outliving its reason.
#
# Lockfiles are read the way Mix reads them, by evaluating the literal. They
# are this repository's own files, not input from anyone else.

defmodule LockDrift do
  @spec main(argv :: [String.t()]) :: no_return()
  def main(argv) do
    case OptionParser.parse(argv, strict: [allow: :keep]) do
      {opts, [reference | others], []} when others != [] ->
        allowed = opts |> Keyword.get_values(:allow) |> Enum.flat_map(&String.split(&1, ","))
        check(reference, others, MapSet.new(allowed, &String.trim/1))

      _usage_error ->
        IO.puts(
          :stderr,
          "usage: elixir scripts/check_lock_drift.exs [--allow NAME,...] REFERENCE_LOCK OTHER_LOCK..."
        )

        System.halt(2)
    end
  end

  defp check(reference, others, allowed) do
    base = read(reference)

    drift =
      for other <- others,
          lock = read(other),
          {name, resolution} <- Enum.sort(base),
          Map.has_key?(lock, name),
          lock[name] != resolution,
          do:
            {name,
             "#{name}: #{reference} has #{describe(resolution)}, #{other} has #{describe(lock[name])}"}

    drifting = MapSet.new(drift, &elem(&1, 0))

    for name <- Enum.sort(allowed), not MapSet.member?(drifting, name) do
      IO.puts("Allowed drift for #{name} no longer drifts; remove it from --allow.")
    end

    for {name, line} <- drift, MapSet.member?(allowed, name) do
      IO.puts("Allowed drift: #{line}")
    end

    case for {name, line} <- drift, not MapSet.member?(allowed, name), do: line do
      [] ->
        IO.puts(
          "No unreviewed dependency drift between #{Enum.join([reference | others], " and ")}."
        )

        System.halt(0)

      lines ->
        IO.puts(
          :stderr,
          "Lockfiles disagree on shared dependencies:\n  " <> Enum.join(lines, "\n  ")
        )

        IO.puts(
          :stderr,
          "Update the stale lock (for example `cd dist/lmx && mix deps.update NAME`)."
        )

        System.halt(1)
    end
  end

  # A Hex dependency is identified by its repository and version, a Git one by
  # its URL and locked revision. Everything else in the tuple (checksums,
  # managers, requirements) follows from those.
  defp read(path) do
    # The same parse options Mix uses: lockfiles quote every key, which the
    # parser would otherwise warn about once per dependency.
    {lock, _bindings} =
      path
      |> File.read!()
      |> Code.string_to_quoted!(
        file: path,
        emit_warnings: false,
        warn_on_unnecessary_quotes: false
      )
      |> Code.eval_quoted([], file: path)

    Map.new(lock, fn {name, entry} -> {to_string(name), resolution(entry)} end)
  end

  defp resolution({:hex, _package, version, _hash, _managers, _deps, repo, _outer}),
    do: {:hex, repo, version}

  defp resolution({:hex, _package, version, _hash, _managers, _deps, repo}),
    do: {:hex, repo, version}

  defp resolution({:git, url, revision, _opts}), do: {:git, url, revision}
  defp resolution(other), do: other

  defp describe({:hex, "hexpm", version}), do: version
  defp describe({:hex, repo, version}), do: "#{version} (#{repo})"
  defp describe({:git, url, revision}), do: "#{url}@#{revision}"
  defp describe(other), do: inspect(other)
end

LockDrift.main(System.argv())

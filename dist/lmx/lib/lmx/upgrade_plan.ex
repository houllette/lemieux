defmodule Lmx.UpgradePlan do
  @moduledoc """
  Durable release decisions, checked before a candidate is built.

  A BEAM diff locates work; it does not establish state compatibility. Drafts
  remain unreviewed and fail the release gate. Every platform needs an explicit
  initial/hot/restart decision, including a reason. Hot decisions additionally
  pin the prior build and explain state, messages, closures and downgrade safety.
  Native/runtime changes and module additions/removals require restart today.

  CI compares the recorded predecessor to the latest stable release, verifies
  its archive checksum, and exercises the actual candidate against it. The
  synthetic upgrade fixture is useful regression evidence, but cannot qualify
  a different published artifact. Human/agent review notes and those executable
  checks serve different purposes; neither can replace the other.
  """

  alias Lmx.Release
  alias Lmx.Update.Archive

  @apps [:lemieux, :lmx]
  @reviews [:state, :messages, :closures, :rollback]

  @doc "Reads the trusted repository's release decision file."
  @spec read!(version :: String.t(), directory :: Path.t()) :: map()
  def read!(version, directory \\ "upgrades") do
    path = Path.join(directory, version <> ".exs")
    require!(File.regular?(path), "missing #{path}; create and review a release decision")
    {plan, _} = Code.eval_file(path)
    validate!(plan, version)
  end

  @doc "Requires a reviewed decision for every platform and, when supplied, the latest stable predecessor."
  @spec validate!(plan :: map(), version :: String.t(), latest :: String.t() | nil | :unspecified) ::
          map()
  def validate!(plan, version, latest \\ :unspecified) do
    require!(
      is_map(plan) and plan[:schema_version] == 1 and plan[:version] == version,
      "upgrade decision schema/version does not match #{version}"
    )

    require!(plan[:reviewed] == true, "upgrade decision is unreviewed")
    require!(is_map(plan[:targets]), "upgrade decision needs all platform decisions")
    from = plan[:from]

    require!(
      is_nil(from) or stable_before?(from, version),
      "predecessor must be an older stable version"
    )

    if latest != :unspecified,
      do:
        require!(
          from == latest,
          "recorded predecessor #{inspect(from)} differs from latest stable #{inspect(latest)}"
        )

    for target <- Release.targets() do
      decision = plan[:targets][target]
      require!(is_map(decision), "missing #{target} upgrade decision")
      require!(decision[:mode] in [:initial, :restart, :hot], "invalid #{target} upgrade mode")
      require!(note?(decision[:reason]), "#{target} needs a reviewed reason")

      require!(
        decision[:mode] == :initial == is_nil(from),
        "initial mode is only for the first public release"
      )

      if decision[:mode] == :hot, do: validate_hot!(decision, target)
    end

    plan
  end

  defp stable_before?(from, version) when is_binary(from) do
    with {:ok, %{pre: []} = old} <- Version.parse(from),
         {:ok, %{pre: []} = new} <- Version.parse(version),
         do: Version.compare(old, new) == :lt,
         else: (_ -> false)
  end

  defp stable_before?(_, _), do: false

  defp validate_hot!(decision, target) do
    require!(target != "windows", "Windows requires a restart decision")
    require!(digest?(decision[:from_build]), "#{target} hot path must pin the exact from_build")
    require!(is_map(decision[:review]), "#{target} hot path needs compatibility review notes")

    for field <- @reviews,
        do: require!(note?(decision[:review][field]), "#{target} needs #{field} review notes")

    modules = decision[:modules]

    require!(
      is_map(modules) and Enum.sort(Map.keys(modules)) == Enum.sort(@apps),
      "hot modules must name lemieux and lmx"
    )

    for app <- @apps do
      list = modules[app]

      require!(
        is_list(list) and Enum.all?(list, &is_atom/1) and Enum.uniq(list) == list,
        "#{app} modules must be a unique list of module atoms"
      )
    end
  end

  defp note?(value),
    do:
      is_binary(value) and String.trim(value) != "" and
        not String.contains?(value, ["UNREVIEWED", "TODO", "REVIEW REQUIRED"])

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  @doc "Inspects the actual unpacked releases; module names are data, not loaded code."
  @spec report(old_root :: Path.t(), new_root :: Path.t()) :: map()
  def report(old_root, new_root) do
    old = metadata!(old_root)
    new = metadata!(new_root)

    %{
      from: old,
      to: new,
      identity_matches: Release.compatible?(old, new),
      changes:
        Map.new(@apps, fn app ->
          {app, diff(old_root, new_root, app, old["version"], new["version"])}
        end)
    }
  end

  @doc "Reads a fresh archive's single release identity."
  @spec metadata!(root :: Path.t()) :: map()
  def metadata!(root) do
    path =
      case File.read(Path.join(root, "releases/start_erl.data")) do
        {:ok, data} ->
          [_erts, version] = String.split(String.trim(data))
          Path.join([root, "releases", version, "release.json"])

        {:error, :enoent} ->
          # Metadata-only fixtures have no boot data. Real releases select their
          # permanent/current build explicitly; a build tree may retain old versions.
          paths = Path.wildcard(Path.join([root, "releases", "*", "release.json"]))
          require!(length(paths) == 1, "expected one release identity in #{root}")
          hd(paths)
      end

    path |> File.read!() |> JSON.decode!()
  end

  defp diff(old_root, new_root, app, old_version, new_version) do
    old = beams(old_root, app, old_version)
    new = beams(new_root, app, new_version)

    %{
      added: (Map.keys(new) -- Map.keys(old)) |> Enum.sort(),
      removed: (Map.keys(old) -- Map.keys(new)) |> Enum.sort(),
      changed:
        for({name, bytes} <- new, Map.has_key?(old, name), old[name] != bytes, do: name)
        |> Enum.sort()
    }
  end

  defp beams(root, app, version) do
    Path.wildcard(Path.join([root, "lib", "#{app}-#{version}", "ebin", "*.beam"]))
    |> Map.new(fn path -> {Path.basename(path, ".beam"), File.read!(path)} end)
  end

  @doc "Checks the pinned source, compatibility identity and exact module coverage of a hot decision."
  @spec qualify!(plan :: map(), target :: String.t(), report :: map()) :: :ok
  def qualify!(plan, target, report) do
    decision = plan.targets[target]
    require!(plan.from == report.from["version"], "plan names a different predecessor version")

    require!(
      decision.from_build == report.from["build_id"],
      "plan names a different predecessor build"
    )

    require!(
      report.identity_matches,
      "runtime, dependencies or native assets changed; review a restart decision"
    )

    for app <- @apps do
      diff = report.changes[app]

      require!(
        diff.added == [] and diff.removed == [],
        "#{app}: module additions/removals require restart"
      )

      modules = Enum.map(decision.modules[app], &Atom.to_string/1) |> Enum.sort()

      require!(
        modules == diff.changed,
        "#{app}: upgrade plan must cover exactly #{inspect(diff.changed)}"
      )
    end

    :ok
  end

  @doc "Produces an unreviewed restart draft and the observed module diff for the build host."
  @spec draft(report :: map()) :: map()
  def draft(report) do
    targets =
      Map.new(
        Release.targets(),
        &{&1, %{mode: :restart, reason: "UNREVIEWED: explain the release decision"}}
      )

    observed = %{
      mode: :restart,
      reason: "UNREVIEWED: inspect the diff and compatibility before choosing hot",
      from_build: report.from["build_id"],
      modules:
        Map.new(@apps, fn app ->
          {app, Enum.map(report.changes[app].changed, &String.to_existing_atom/1)}
        end),
      review: Map.new(@reviews, &{&1, "UNREVIEWED"})
    }

    %{
      schema_version: 1,
      version: report.to["version"],
      from: report.from["version"],
      reviewed: false,
      targets: Map.put(targets, report.to["target"], observed)
    }
  end

  @doc "Verifies a previous archive against SHA256SUMS before safe, fresh extraction."
  @spec unpack!(archive :: Path.t(), sums :: Path.t(), destination :: Path.t()) :: :ok
  def unpack!(archive, sums, destination) do
    require!(
      !File.exists?(destination),
      "previous release must be unpacked into a fresh directory"
    )

    require!(File.stat!(archive).size <= 150_000_000, "previous archive exceeds download limit")
    name = Path.basename(archive)

    entries =
      sums
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, ~r/\s+/, parts: 2))

    expected = for [sha, ^name] <- entries, do: sha
    digest = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    require!(expected == [digest], "previous archive checksum mismatch or duplicate")
    require!(Archive.validate(archive) == :ok, "unsafe previous release archive")
    File.mkdir_p!(destination)

    require!(
      :erl_tar.extract(to_charlist(archive), [:compressed, cwd: to_charlist(destination)]) == :ok,
      "previous release extraction failed"
    )

    metadata!(destination)
    :ok
  end

  defp require!(true, _message), do: :ok
  defp require!(_, message), do: Mix.raise(message)
end

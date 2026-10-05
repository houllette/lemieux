# Regenerates notices/crates.txt: the Rust crates linked into the ex_ratatui
# terminal NIF that lmx archives bundle, with each crate's license and
# copyright lines, and fetches any SPDX license text notices/licenses/ lacks.
#
#     cd dist/lmx && mise exec -- mix deps.get
#     mise exec -- elixir notices/generate_crates.exs
#
# Needs cargo and network access (crate sources and license texts). Review the
# diff before committing: the output is shipped in THIRD_PARTY_NOTICES, and
# Lmx.Notices refuses to build an archive whose ex_ratatui version or
# Cargo.lock no longer matches what this file records.
#
# A crate counts when it is a normal (not build or dev) dependency that is not
# a procedural macro, for any of the four lmx targets: those are the crates
# compiled into the NIF. Build scripts and macros run on the build machine and
# are not redistributed.
#
# Where a crate offers a choice ("MIT OR Apache-2.0"), lmx takes the first
# license of @preference the expression allows, and only the chosen licenses'
# texts are reproduced. Nothing here chooses a copyleft license; a crate that
# leaves no other choice stops the generator, because it needs a person's
# decision rather than a notice.

defmodule CrateNotices do
  @crate "deps/ex_ratatui/native/ex_ratatui"
  @targets ~w(aarch64-apple-darwin x86_64-apple-darwin x86_64-unknown-linux-gnu x86_64-pc-windows-msvc)
  @spdx "https://raw.githubusercontent.com/spdx/license-list-data/v3.29.0/text/"
  @preference ~w(MIT Apache-2.0 BSD-3-Clause BSD-2-Clause ISC Zlib 0BSD BSL-1.0 Unicode-3.0
                 Unicode-DFS-2016 Unlicense CC0-1.0)
  @license_files ~r/^(licen[cs]e|copying|copyright|notice)/i
  # Lines that belong to a license's own text or template, not to the crate.
  @boilerplate ~r/\[yyyy\]|<year>|\{yyyy\}|\[name of copyright owner\]|<copyright holders?>|free software foundation/i

  def run do
    manifest = Path.join(@crate, "Cargo.toml")
    lock = Path.join(@crate, "Cargo.lock")
    version = ex_ratatui_version()
    cargo!(["fetch", "--locked", "--manifest-path", manifest])
    packages = metadata(manifest)

    crates =
      manifest
      |> linked()
      |> Enum.map(fn {key, targets} -> describe(Map.fetch!(packages, key), targets) end)
      |> Enum.sort_by(&{&1.name, &1.version})

    ids =
      crates |> Enum.flat_map(& &1.used) |> Enum.flat_map(&ids/1) |> Enum.uniq() |> Enum.sort()

    Enum.each(ids, &ensure_license_text/1)
    File.write!("notices/crates.txt", render(version, sha256(File.read!(lock)), crates, ids))

    IO.puts(
      "wrote notices/crates.txt: #{length(crates)} crates, licenses #{Enum.join(ids, ", ")}"
    )
  end

  defp ex_ratatui_version do
    {:ok, terms} = :file.consult(~c"deps/ex_ratatui/hex_metadata.config")
    terms |> Map.new() |> Map.fetch!("version")
  end

  defp cargo!(args) do
    case System.cmd("cargo", args) do
      {output, 0} -> output
      {output, status} -> raise "cargo #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  # Every package cargo knows about, keyed by {name, version}.
  defp metadata(manifest) do
    cargo!(["metadata", "--locked", "--format-version", "1", "--manifest-path", manifest])
    |> JSON.decode!()
    |> Map.fetch!("packages")
    |> Map.new(fn package -> {{package["name"], package["version"]}, package} end)
  end

  # {name, version} => the targets it is linked for.
  defp linked(manifest) do
    for target <- @targets,
        line <- tree(manifest, target),
        reduce: %{} do
      acc ->
        [name, "v" <> version | _rest] = String.split(line, " ")
        Map.update(acc, {name, version}, [target], &Enum.uniq([target | &1]))
    end
  end

  defp tree(manifest, target) do
    ["tree", "--locked", "--manifest-path", manifest, "--target", target]
    |> Kernel.++(["--edges", "normal,no-proc-macro", "--prefix", "none", "--format", "{p}"])
    |> cargo!()
    |> String.split("\n", trim: true)
  end

  defp describe(package, targets) do
    dir = Path.dirname(package["manifest_path"])
    files = license_files(dir)

    # The NIF's own manifest declares no license; its Hex package is MIT.
    declared =
      case {package["name"], package["license"]} do
        {"ex_ratatui", nil} -> "MIT"
        {_name, nil} -> nil
        # Cargo still accepts the deprecated "/" separator.
        {_name, expression} -> String.replace(expression, "/", " OR ")
      end

    used = if declared, do: choose(parse(declared), package["name"]), else: []

    %{
      name: package["name"],
      version: package["version"],
      declared: declared,
      used: used,
      targets: if(length(targets) == length(@targets), do: :all, else: Enum.sort(targets)),
      copyright: copyright(files),
      notices: notices(package, dir, files, declared)
    }
  end

  defp license_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@license_files, &1))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.regular?/1)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp copyright(files) do
    files
    |> Enum.flat_map(fn file -> file |> File.read!() |> String.split(["\r\n", "\n"]) end)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(~r/^(copyright|\(c\)|©)\b.*\d{4}|^copyright \(c\) the /i, &1))
    |> Enum.reject(&Regex.match?(@boilerplate, &1))
    |> Enum.uniq()
  end

  # Texts a license name alone does not cover: NOTICE files (Apache-2.0
  # section 4(d)), a crate without an SPDX expression, code a -sys crate
  # bundles under its own license, and the NIF's own extra assets.
  defp notices(package, dir, files, declared) do
    notice_files = Enum.filter(files, &Regex.match?(~r/notice/i, Path.basename(&1)))
    unlicensed = if declared == nil, do: files, else: []

    bundled =
      if String.ends_with?(package["name"], ["-sys", "_sys"]),
        do: nested_license_files(Path.join(dir, "*/*")),
        else: []

    own =
      if package["name"] == "ex_ratatui",
        do:
          nested_license_files(Path.join(dir, "syntaxes/*")) ++
            nested_license_files(Path.join(dir, "vendor/*/*")),
        else: []

    (notice_files ++ unlicensed ++ bundled ++ own)
    |> Enum.uniq()
    |> Enum.map(&{Path.relative_to(&1, dir), File.read!(&1)})
  end

  defp nested_license_files(pattern) do
    pattern
    |> Path.wildcard()
    |> Enum.filter(&(File.regular?(&1) and Regex.match?(@license_files, Path.basename(&1))))
    |> Enum.sort()
  end

  # SPDX license expressions: or := and (OR and)*; and := atom (AND atom)*;
  # atom := ( or ) | ID [WITH ID].
  defp parse(expression) do
    tokens = Regex.scan(~r/\(|\)|[A-Za-z0-9.+-]+/, expression) |> List.flatten()

    case parse_or(tokens) do
      {tree, []} -> tree
      {_tree, rest} -> raise "cannot parse license #{inspect(expression)} at #{inspect(rest)}"
    end
  end

  defp parse_or(tokens) do
    {left, rest} = parse_and(tokens)

    case rest do
      ["OR" | more] ->
        {right, rest} = parse_or(more)
        {{:or, left, right}, rest}

      _ ->
        {left, rest}
    end
  end

  defp parse_and(tokens) do
    {left, rest} = parse_atom(tokens)

    case rest do
      ["AND" | more] ->
        {right, rest} = parse_and(more)
        {{:and, left, right}, rest}

      _ ->
        {left, rest}
    end
  end

  defp parse_atom(["(" | tokens]) do
    {tree, [")" | rest]} = parse_or(tokens)
    {tree, rest}
  end

  defp parse_atom([id, "WITH", exception | rest]),
    do: {{:license, id <> " WITH " <> exception}, rest}

  defp parse_atom([id | rest]), do: {{:license, id}, rest}

  # The licenses lmx relies on for one crate: every part of an AND, the most
  # preferred side of an OR.
  defp choose(tree, crate) do
    choice = tree |> options() |> Enum.min_by(&rank/1)

    if Enum.all?(choice, &(base(&1) in @preference)),
      do: choice,
      else: raise("#{crate}: needs a person's decision, it offers only #{inspect(choice)}")
  end

  defp options({:license, id}), do: [[id]]
  defp options({:or, left, right}), do: options(left) ++ options(right)

  defp options({:and, left, right}),
    do: for(a <- options(left), b <- options(right), do: Enum.uniq(a ++ b))

  # Lower is better: the least preferred license a choice needs, then how
  # many licenses it needs.
  defp rank(licenses) do
    worst = licenses |> Enum.map(&(&1 |> base() |> preference())) |> Enum.max()
    {worst, length(licenses)}
  end

  defp base(license), do: license |> String.split(" WITH ") |> hd()

  defp preference(id), do: Enum.find_index(@preference, &(&1 == id)) || length(@preference)

  # License and exception identifiers named by a chosen license.
  defp ids(license), do: String.split(license, " WITH ")

  defp ensure_license_text(id) do
    path = Path.join("notices/licenses", id <> ".txt")

    unless File.exists?(path) do
      {:ok, _} = Application.ensure_all_started([:inets, :ssl])
      url = String.to_charlist(@spdx <> id <> ".txt")

      case :httpc.request(:get, {url, []}, [ssl: ssl()], body_format: :binary) do
        # Some SPDX templates end lines with spaces, which the repository's
        # .editorconfig trims; strip them here so a regenerated text matches.
        {:ok, {{_, 200, _}, _headers, body}} ->
          File.write!(path, String.replace(body, ~r/[ \t]+$/m, ""))

        other ->
          raise "cannot fetch the SPDX text for #{id}: #{inspect(other)}"
      end
    end
  end

  defp ssl do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp render(version, lock_digest, crates, ids) do
    header = """
    Rust crates in the ex_ratatui terminal NIF
    ==========================================

    ex_ratatui: #{version}
    Cargo.lock sha256: #{lock_digest}
    Targets: #{Enum.join(@targets, ", ")}
    Licenses: #{Enum.join(ids, ", ")}

    The terminal library's native code (lib/ex_ratatui-#{version}/priv/native)
    is compiled from these crates. Each entry gives the crate, its version and
    its declared license; where the crate offers a choice, the license lmx
    uses it under follows "used under". The copyright lines its license files
    carry are listed beneath it, and a crate linked on some targets only lists
    them. The full text of every license used here is in the License texts
    section of this file.

    """

    entries = Enum.map_join(crates, "", &entry/1)

    extra =
      crates
      |> Enum.flat_map(fn crate -> Enum.map(crate.notices, &{crate, &1}) end)
      |> Enum.map_join("", fn {crate, {file, text}} ->
        "\n--- #{crate.name} #{crate.version}: #{file} ---\n\n" <>
          String.trim_trailing(text) <> "\n"
      end)

    files =
      if extra == "",
        do: "",
        else: "\nFiles these crates carry\n------------------------\n" <> extra

    header <> entries <> files
  end

  defp entry(crate) do
    targets = if crate.targets == :all, do: "", else: "  (#{Enum.join(crate.targets, ", ")})"

    license =
      case crate do
        %{declared: nil} -> "no SPDX expression; see its license file below"
        %{declared: declared, used: [declared]} -> declared
        %{declared: declared, used: used} -> "#{declared}; used under #{Enum.join(used, " AND ")}"
      end

    "#{crate.name} #{crate.version}: #{license}#{targets}\n" <>
      Enum.map_join(crate.copyright, "", &"    #{&1}\n")
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end

CrateNotices.run()

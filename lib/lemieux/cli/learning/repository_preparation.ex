defmodule Lemieux.CLI.Learning.RepositoryPreparation do
  @moduledoc """
  Prepares SWE-derived development fixtures without model requests.

  The cached source image supplies an exact Git archive, never its current
  HEAD. Public checks, private tests and the reference implementation remain
  separate, and original verification bytes are restored in the oracle. The
  prepared image already owns Python and pytest; neither is installed here.
  Commands use the host's bounded process runner, including deadline cleanup.
  """
  import Bitwise

  alias Lemieux.Contract
  alias Lemieux.Environment
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox

  @spec prepare(opts :: keyword(), runner :: ([String.t()], keyword() -> binary())) :: Path.t()
  def prepare(opts, runner \\ &run/2) do
    instance = instance!(opts)
    image = Keyword.fetch!(opts, :image)
    validate_images!(opts, runner)
    root = opts |> Keyword.fetch!(:output) |> Path.expand()
    File.mkdir_p!(Path.dirname(root))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    write_json(Path.join(root, "instance.private.json"), instance)
    File.chmod!(Path.join(root, "instance.private.json"), 0o600)

    archive =
      runner.(
        [
          "docker",
          "run",
          "--rm",
          "--network",
          "none",
          "--read-only",
          "--entrypoint",
          "git",
          Keyword.fetch!(opts, :source_image),
          "-C",
          "/testbed",
          "archive",
          instance["base_commit"]
        ],
        []
      )

    public = File.read!(Keyword.fetch!(opts, :public_check))
    source = Path.join(root, "source")
    safe_extract(archive, source)
    File.write!(Path.join(root, "source.tar"), archive)
    File.write!(Path.join(source, "test_qualification_public.py"), public)

    File.write!(
      Path.join(source, "qualification_pytest.ini"),
      "[pytest]\naddopts = -q -p no:cacheprovider\n"
    )

    frozen =
      source
      |> file_digests()
      |> Map.keys()
      |> Enum.filter(&verification_file?/1)
      |> Kernel.++(["qualification_pytest.ini", "qualification-contract.json"])
      |> Enum.uniq()
      |> Enum.sort()

    write_json(Path.join(source, "qualification-contract.json"), %{
      "schema_version" => 1,
      "paths" => frozen
    })

    tests = Path.join(root, "tests.private.patch")
    gold = Path.join(root, "gold.private.patch")
    File.write!(tests, instance["test_patch"])
    File.write!(gold, instance["patch"])
    prepare_private(source, root, tests, instance)
    project_oracle(source, Path.join(root, "oracle"), gold, frozen)

    template = template(opts, instance, root, source, frozen, archive, public, image)
    path = Path.join(root, "template.json")
    write_json(path, template)

    runner.(["mix", "run", "scripts/freeze_learning_repository.exs", "--template", path],
      cwd: Keyword.fetch!(opts, :repo),
      timeout_ms: 1_200_000
    )

    Path.join(root, "manifest.json")
  end

  defp instance!(opts) do
    source = Keyword.fetch!(opts, :source_image)
    image = Keyword.fetch!(opts, :image)

    unless String.contains?(source, "@sha256:") and String.starts_with?(image, "sha256:"),
      do: raise(ArgumentError, "source and prepared images require immutable identities")

    dataset = opts |> Keyword.fetch!(:dataset) |> File.read!() |> JSON.decode!()

    case Enum.filter(dataset, &(&1["instance_id"] == Keyword.fetch!(opts, :instance))) do
      [%{"base_commit" => base} = instance] ->
        unless Regex.match?(~r/\A[a-f0-9]{40}\z/, base),
          do: raise(ArgumentError, "invalid task base commit")

        instance

      _invalid ->
        raise ArgumentError, "instance must occur exactly once in the private dataset"
    end
  end

  defp validate_images!(opts, runner) do
    image = Keyword.fetch!(opts, :image)

    info =
      ["docker", "image", "inspect", image, "--format", "{{json .}}"]
      |> runner.([])
      |> JSON.decode!()

    environment =
      Map.new(info["Config"]["Env"], fn pair ->
        pair |> String.split("=", parts: 2) |> List.to_tuple()
      end)

    unless environment["PYTHONDONTWRITEBYTECODE"] == "1" and
             String.contains?(Map.get(environment, "PYTEST_ADDOPTS", ""), "no:cacheprovider"),
           do:
             raise(
               ArgumentError,
               "prepared image must disable Python bytecode and pytest cache writes"
             )

    runner.(
      [
        "docker",
        "run",
        "--rm",
        "--network",
        "none",
        "--read-only",
        "--entrypoint",
        "sh",
        image,
        "-c",
        "test ! -e /testbed && python3 -I -B -c 'import pytest'"
      ],
      timeout_ms: 30_000
    )
  end

  @doc "Validates a bounded, link-free archive before writing any member."
  @spec safe_extract(data :: binary(), destination :: Path.t()) :: :ok
  def safe_extract(data, destination) do
    with true <- byte_size(data) <= 128_000_000,
         {:ok, rows} <- :erl_tar.table({:binary, data}, [:verbose]),
         true <- length(rows) <= 25_000,
         true <- Enum.reduce(rows, 0, &(&2 + elem(&1, 2))) <= 256_000_000,
         true <- Enum.all?(rows, &safe_member?/1),
         true <- unique_members?(rows) do
      unless File.lstat(destination) == {:error, :enoent},
        do: raise(ArgumentError, "archive destination already exists")

      File.mkdir_p!(destination)
      :ok = :erl_tar.extract({:binary, data}, cwd: String.to_charlist(destination))

      for {name, :regular, _size, _mtime, mode, _uid, _gid} <- rows do
        File.chmod!(Path.join(destination, to_string(name)), extraction_mode(mode))
      end

      :ok
    else
      _unsafe -> raise ArgumentError, "unsafe or oversized preparation archive"
    end
  end

  defp extraction_mode(mode) do
    mode = if (mode &&& 0o100) == 0, do: mode &&& bnot(0o111), else: mode
    (mode &&& 0o755) ||| 0o600
  end

  defp safe_member?({name, type, size, _mtime, _mode, _uid, _gid}) do
    name = name |> to_string() |> String.trim_trailing("/")
    type in [:regular, :directory] and size in 0..16_000_000 and relative?(name)
  end

  defp unique_members?(rows) do
    paths =
      Map.new(rows, fn row ->
        {row |> elem(0) |> to_string() |> String.trim_trailing("/"), elem(row, 1)}
      end)

    map_size(paths) == length(rows) and
      Enum.all?(paths, fn {name, _type} -> directory_parents?(Path.dirname(name), paths) end)
  end

  defp directory_parents?(".", _paths), do: true

  defp directory_parents?(name, paths),
    do:
      Map.get(paths, name, :directory) == :directory and
        directory_parents?(Path.dirname(name), paths)

  defp relative?(path) do
    Path.type(path) == :relative and not String.contains?(path, ["\\", ":", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  @doc "Applies a patch in an isolated Git repository and requires changed source bytes."
  @spec apply_patch(directory :: Path.t(), patch :: Path.t()) :: [String.t()]
  def apply_patch(directory, patch) do
    directory = Path.expand(directory)
    git = Path.join(directory, ".git")

    unless File.lstat(git) == {:error, :enoent},
      do: raise(ArgumentError, "patch destination already contains Git metadata")

    before = file_digests(directory)

    try do
      run(["git", "-c", "init.templateDir=", "init", "-q", directory], [])
      run(["git", "-C", directory, "apply", "--check", Path.expand(patch)], [])
      run(["git", "-C", directory, "apply", Path.expand(patch)], [])
    after
      File.rm_rf!(git)
    end

    after_patch = file_digests(directory)

    changed =
      (Map.keys(before) ++ Map.keys(after_patch))
      |> Enum.uniq()
      |> Enum.filter(&(before[&1] != after_patch[&1]))
      |> Enum.sort()

    if changed == [], do: raise(ArgumentError, "patch changed no source bytes")
    changed
  end

  @doc "Copies and patches a reference implementation, then restores frozen verification files."
  @spec project_oracle(
          source :: Path.t(),
          oracle :: Path.t(),
          patch :: Path.t(),
          frozen :: [String.t()]
        ) :: :ok
  def project_oracle(source, oracle, patch, frozen) do
    File.cp_r!(source, oracle)
    apply_patch(oracle, patch)

    for name <- frozen do
      target = Path.join(oracle, name)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(source, name), target)
    end

    :ok
  end

  @doc "Preserves pytest file closure and selects complete parameterized function families."
  @spec pytest_selection(selectors :: [String.t()]) :: {[String.t()], [String.t()]}
  def pytest_selection([]), do: raise(ArgumentError, "empty pytest selection")

  def pytest_selection(selectors) do
    {paths, names} = Enum.reduce(selectors, {[], []}, &select_pytest/2)
    {paths |> Enum.uniq() |> Enum.sort(), Enum.uniq(names)}
  end

  defp select_pytest(selector, {paths, names}) do
    # Parameter IDs do not enter the generated configuration, but still reject
    # control characters before stripping them so the accepted input stays explicit.
    if String.contains?(selector, ["\n", "\r", <<0>>]),
      do: raise(ArgumentError, "unsafe pytest selector")

    parts = String.split(selector, "::")
    name = parts |> List.last() |> String.split("[", parts: 2) |> hd()
    unless identifier?(name), do: raise(ArgumentError, "unsupported pytest function selector")
    {select_path(parts, paths), names ++ [name]}
  end

  defp select_path([_function], paths), do: paths

  defp select_path([path | rest], paths) do
    classes = Enum.drop(rest, -1)

    unless String.ends_with?(path, ".py") and relative?(path) and
             Enum.all?(String.split(path, "/"), &Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, &1)) and
             Enum.all?(classes, &identifier?/1),
           do: raise(ArgumentError, "unsafe or unsupported pytest node ID")

    [path | paths]
  end

  defp identifier?(value), do: Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, value)

  defp file_digests(directory),
    do: Map.new(source_files(directory), fn name -> {name, sha(Path.join(directory, name))} end)

  defp source_files(directory, relative \\ "") do
    directory
    |> Path.join(relative)
    |> File.ls!()
    |> Enum.reject(&(&1 == ".git"))
    |> Enum.flat_map(fn name ->
      path = if relative == "", do: name, else: relative <> "/" <> name

      case File.lstat!(Path.join(directory, path)) do
        %{type: :regular} -> [path]
        %{type: :directory} -> source_files(directory, path)
        %{type: :symlink} -> raise ArgumentError, "patch/source contains a symlink"
        _special -> raise ArgumentError, "patch/source contains a special file"
      end
    end)
  end

  defp verification_file?(path) do
    name = Path.basename(path)

    String.starts_with?(name, "test_") or name == "conftest.py" or "tests" in Path.split(path) or
      Path.extname(path) in ~w(.md .rst .sh .lock) or
      name in ~w(Makefile setup.cfg setup.py pyproject.toml pytest.ini)
  end

  defp prepare_private(source, root, patch, instance) do
    preparation = Path.join(root, "private-test-preparation")
    File.cp_r!(source, preparation)
    changed = apply_patch(preparation, patch)
    {selected, names} = pytest_selection(instance["FAIL_TO_PASS"] ++ instance["PASS_TO_PASS"])
    paths = Enum.uniq(changed ++ selected)
    conftests = Enum.flat_map(paths, &conftests(preparation, Path.dirname(&1)))
    private = Path.join(root, "private-tests")
    File.mkdir!(private)

    for name <- Enum.sort(Enum.uniq(paths ++ conftests)) do
      unless verification_file?(name) and File.regular?(Path.join(preparation, name)),
        do: raise(ArgumentError, "unsupported private test change: #{name}")

      target = Path.join(private, name)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(preparation, name), target)
    end

    if File.regular?(Path.join(source, "conftest.py")),
      do: File.cp!(Path.join(source, "conftest.py"), Path.join(private, "conftest.py"))

    File.write!(
      Path.join(private, "pytest.ini"),
      "[pytest]\naddopts = -k \"" <> Enum.join(names, " or ") <> "\"\n"
    )
  end

  defp conftests(root, parent) do
    path = if parent == ".", do: "conftest.py", else: parent <> "/conftest.py"
    current = if File.regular?(Path.join(root, path)), do: [path], else: []
    if parent == ".", do: current, else: current ++ conftests(root, Path.dirname(parent))
  end

  defp template(opts, instance, root, source, frozen, archive, public, image) do
    %{
      "schema_version" => 1,
      "metadata" => %{
        "id" => Keyword.fetch!(opts, :instance) <> "-development",
        "exposure" => "developer_exposed",
        "base_commit" => instance["base_commit"],
        "dataset_sha256" => sha(Keyword.fetch!(opts, :dataset)),
        "source_image" => Keyword.fetch!(opts, :source_image),
        "source_archive_sha256" => Contract.sha256(archive),
        "public_check_sha256" => Contract.sha256(public),
        "grading" => "SWE-derived private pytest subset; not the official SWE-bench evaluator",
        "selectors_policy" => "complete_function_families_in_selected_files/v1",
        "oracle_policy" => "reference_implementation_with_original_immutable_bytes/v1",
        "independent_confirmation" => "not_run"
      },
      "tasks" => [
        %{
          "id" => String.replace(Keyword.fetch!(opts, :instance), "__", "-"),
          "cluster" => String.replace(instance["repo"], "/", "-"),
          "phase" => "learning",
          "source" => source,
          "private_tests" => Path.join(root, "private-tests"),
          "image" => image,
          "immutable_paths" => frozen,
          "immutable_contract" => "qualification-contract.json",
          "public_pytest_args" => [
            "-c",
            "qualification_pytest.ini",
            "test_qualification_public.py"
          ],
          "prompt" =>
            instance["problem_statement"] <>
              "\nThe repository is at /app. Use its existing Python environment. Reproduce with python3 -m pytest -c qualification_pytest.ini test_qualification_public.py, inspect neighboring implementations, repair the cause and verify relevant regressions."
        }
      ]
    }
  end

  defp run([command | _args] = argv, opts) do
    {:ok, stream} =
      Environment.run(Local.new(), Enum.map_join(argv, " ", &Sandbox.quote_shell/1),
        cwd: Keyword.get(opts, :cwd, File.cwd!()),
        timeout_ms: Keyword.get(opts, :timeout_ms, 180_000),
        max_output_bytes: 128_000_000
      )

    events = Enum.to_list(stream)

    unless List.last(events) == {:exit_status, 0},
      do: raise("preparation command failed (#{command}): #{inspect(List.last(events))}")

    for {:data, bytes} <- events, into: "", do: bytes
  end

  defp sha(path), do: path |> File.read!() |> Contract.sha256()
  defp write_json(path, value), do: File.write!(path, Contract.encode!(value) <> "\n")
end

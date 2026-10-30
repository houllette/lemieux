defmodule Lemieux.CLI.Learning.Projects.Corpus do
  @moduledoc """
  Native preparation of repository-shaped development diagnostics.

  Python belongs to the repositories being repaired, including their reference
  solutions, rather than to the host that prepares them. The frozen examples
  and answers are data; fresh parameters preserve their contracts and family
  clusters. Only allocation needs a new calculation when its total changes.
  Reference source and private answers stay outside the task workspace.
  """

  @spec materialize(root :: Path.t(), partition :: String.t(), variants :: pos_integer()) :: [
          map()
        ]
  def materialize(root, partition, variants)
      when partition in ~w(seed development confirmation) and is_integer(variants) and
             variants > 0 do
    families =
      :lemieux
      |> Application.app_dir("priv/qualification/project_cases.json")
      |> File.read!()
      |> JSON.decode!()

    for family <- families, variant <- 1..variants do
      materialize_family(Path.expand(root), partition, variant, family)
    end
  end

  defp materialize_family(
         root,
         partition,
         variant,
         %{"family" => family, "cases" => cases} = data
       ) do
    id = "#{partition}-#{family}-#{variant}"
    cwd = Path.join(root, id)
    public = fresh_cases(family, cases, "public-" <> partition, variant)
    private = fresh_cases(family, cases, "private-" <> partition, variant)
    files = files(id, family, data["contract"], public)

    for {name, bytes} <- files do
      target = Path.join(cwd, name)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, bytes)
    end

    mutable =
      ~w(src/project/core.py src/project/policy.py .build/project/core.py .build/project/policy.py)

    %{
      "id" => id,
      "cluster" => family,
      "cwd" => cwd,
      "cases" => private,
      "probe_cases" => public,
      "immutable" => Map.drop(files, mutable),
      "reference_guidance" =>
        "Batch-read ISSUE.md, docs/contract.md, docs/development.md, src/project/core.py and src/project/policy.py. Implement in source; rebuild the generated runtime with python tools/build.py; execute public checks; verify edge cases from the written contract and inspect both source and built runtime. Do not treat the old generated copy as authoritative.",
      "offline_oracle" =>
        File.read!(
          Application.app_dir(:lemieux, "priv/qualification/project_oracles/#{family}.py")
        )
    }
  end

  defp files(id, family, contract, public) do
    files = %{
      "README.md" =>
        "Repository case #{id}. A small repository with a generated runtime. Read docs/development.md before changing code. The issue is in ISSUE.md.\n",
      "ISSUE.md" =>
        "Repair the #{family} feature end to end. The authoritative behavior is in docs/contract.md. Preserve the JSON CLI and all existing contracts. Do not edit tests, docs, runner, or build tooling.\n",
      "docs/contract.md" =>
        contract <>
          "\nThe JSON CLI applies solve independently to every input and emits a JSON list.\n",
      "docs/development.md" =>
        "Source lives under src/project. main.py imports the GENERATED runtime from .build/project, which is initially stale. Edit source, run python tools/build.py, then python checks.py. Both source and generated runtime must agree at delivery. The grader may rebuild from source. Python standard library only. Do not put implementations in the CLI or build script.\n",
      "src/project/__init__.py" => "",
      "src/project/core.py" =>
        "from .policy import valid\n\ndef solve(value):\n    if not valid(value):\n        return None\n    return value\n",
      "src/project/policy.py" => "def valid(value):\n    return value is not None\n",
      ".build/project/__init__.py" => "",
      ".build/project/core.py" => "def solve(value):\n    return None\n",
      ".build/project/policy.py" => "def valid(value):\n    return False\n",
      "main.py" =>
        "import json,sys\nsys.path.insert(0, '.build')\nfrom project.core import solve\nprint(json.dumps([solve(x) for x in json.loads(sys.argv[1])]))\n",
      "tools/build.py" =>
        "import pathlib,shutil\nroot=pathlib.Path(__file__).resolve().parents[1]\nshutil.rmtree(root/'.build', ignore_errors=True)\nshutil.copytree(root/'src', root/'.build')\nprint('runtime rebuilt')\n",
      "pyproject.toml" =>
        "[project]\nname = \"workflow-diagnostic\"\nversion = \"0.1.0\"\nrequires-python = \">=3.11\"\n",
      # A JSON string literal is valid Python for these ASCII fixture bytes;
      # encode twice so booleans/null remain JSON inside json.loads.
      "checks.py" =>
        "import json,subprocess,sys\ncases=json.loads(" <>
          JSON.encode!(JSON.encode!(public)) <>
          ")\nactual=json.loads(subprocess.check_output([sys.executable,'main.py',json.dumps([x for x,_ in cases])]))\nassert actual==[y for _,y in cases], (actual,cases)\nprint('public checks passed')\n"
    }

    Enum.reduce(0..11, files, fn index, acc ->
      Map.put(
        acc,
        "src/project/legacy_#{index}.py",
        "\"\"\"Retired adapter #{index}; not imported by the current runtime.\"\"\"\nVERSION = #{index}\n"
      )
    end)
  end

  defp fresh_cases(family, cases, partition, variant) do
    prefix = "#{partition}-#{variant}-"
    offset = variant * 17 + Enum.sum(String.to_charlist(partition))

    Enum.map(cases, fn [input, expected] ->
      fresh = fresh_input(family, input, prefix, offset)
      [fresh, fresh_expected(family, expected, fresh, prefix, offset)]
    end)
  end

  defp fresh_input("graph", input, prefix, _offset) do
    %{
      "nodes" => Enum.map(input["nodes"], &(prefix <> &1)),
      "edges" =>
        Enum.map(input["edges"], fn [child, parent] -> [prefix <> child, prefix <> parent] end)
    }
  end

  defp fresh_input("journal", input, prefix, _offset),
    do: Enum.map(input, &journal_key(&1, prefix))

  defp fresh_input("cache", input, prefix, offset) do
    Map.update!(input, "events", fn events ->
      Enum.map(events, fn [time, op, key | rest] -> [time + offset, op, prefix <> key | rest] end)
    end)
  end

  defp fresh_input("merge", input, prefix, _offset),
    do: Enum.map(input, &rename(&1, prefix, ["$delete"]))

  defp fresh_input("reconcile", input, prefix, offset) do
    Enum.map(input, fn event ->
      event
      |> Map.update!("id", &(prefix <> &1))
      |> Map.update!("version", &shift_version(&1, offset))
    end)
  end

  defp fresh_input("intervals", input, _prefix, offset), do: scale_intervals(input, offset)

  defp fresh_input("allocation", input, _prefix, offset),
    do: Map.update!(input, "total", &shift_total(&1, offset))

  defp fresh_input("patch", input, prefix, _offset) do
    input
    |> Map.update!("document", &rename(&1, prefix, [""]))
    |> Map.update!("operations", fn operations ->
      Enum.map(operations, &fresh_operation(&1, prefix))
    end)
  end

  defp fresh_operation(operation, prefix) do
    operation = Map.update!(operation, "path", &pointer(&1, prefix))

    if Map.has_key?(operation, "value"),
      do: Map.update!(operation, "value", &rename(&1, prefix, [""])),
      else: operation
  end

  defp fresh_expected(_family, nil, _input, _prefix, _offset), do: nil

  defp fresh_expected("graph", value, _input, prefix, _offset),
    do: Enum.map(value, fn layer -> Enum.map(layer, &(prefix <> &1)) end)

  defp fresh_expected("journal", value, _input, prefix, _offset),
    do: Map.new(value, fn {key, item} -> {prefix <> key, item} end)

  defp fresh_expected("merge", value, _input, prefix, _offset),
    do: rename(value, prefix, ["$delete"])

  defp fresh_expected("reconcile", value, _input, prefix, _offset),
    do: Enum.map(value, &Map.update!(&1, "id", fn key -> prefix <> key end))

  defp fresh_expected("intervals", value, _input, _prefix, offset),
    do: scale_intervals(value, offset)

  defp fresh_expected("patch", value, _input, prefix, _offset),
    do: Map.update!(value, "document", &rename(&1, prefix, [""]))

  defp fresh_expected("allocation", _value, input, _prefix, _offset), do: allocate(input)
  defp fresh_expected("cache", value, _input, _prefix, _offset), do: value

  defp allocate(%{"total" => 0, "weights" => weights}), do: Enum.map(weights, fn _ -> 0 end)

  defp allocate(%{"total" => total, "weights" => weights}) do
    denominator = Enum.sum(weights)
    floors = Enum.map(weights, &div(total * &1, denominator))

    winners =
      weights
      |> Enum.with_index()
      |> Enum.sort_by(fn {weight, index} -> {-rem(total * weight, denominator), index} end)
      |> Enum.take(total - Enum.sum(floors))
      |> MapSet.new(fn {_weight, index} -> index end)

    floors
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      value + if(MapSet.member?(winners, index), do: 1, else: 0)
    end)
  end

  defp journal_key([op, key | rest], prefix), do: [op, prefix <> key | rest]
  defp journal_key(event, _prefix), do: event
  defp shift_version(value, offset) when is_integer(value) and value >= 0, do: value + offset
  defp shift_version(value, _offset), do: value
  defp shift_total(value, offset) when is_integer(value) and value > 0, do: value + offset
  defp shift_total(value, _offset), do: value

  defp scale_intervals(value, offset),
    do: Enum.map(value, fn [start, stop, weight] -> [start * offset, stop * offset, weight] end)

  defp rename(value, prefix, unchanged) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {if(key in unchanged, do: key, else: prefix <> key), rename(item, prefix, unchanged)}
    end)
  end

  defp rename(value, _prefix, _unchanged), do: value

  defp pointer("/" <> path, prefix) do
    keys =
      path
      |> String.split("/")
      |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))

    "/" <>
      Enum.map_join(keys, "/", fn key ->
        renamed = if key == "", do: key, else: prefix <> key
        renamed |> String.replace("~", "~0") |> String.replace("/", "~1")
      end)
  end

  defp pointer(path, _prefix), do: path
end

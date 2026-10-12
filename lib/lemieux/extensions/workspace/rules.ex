defmodule Lemieux.Extensions.Workspace.Rules do
  @moduledoc """
  Bounded Claude-compatible rules with path-aware activation.

  Unscoped rules enter the marked workspace layer immediately. Before a
  matching native file tool runs, its new scoped rules are checkpointed and
  the call is denied once. The next request receives their guidance before
  retrying, so a write cannot precede the rule. Only digests survive in the
  document: current discovery supplies bodies after resume or compaction.

  Patterns are root-anchored, including `*.md`. Malformed scope is skipped
  with a diagnostic rather than broadened to every file. The shared glob
  frontend supports globstars, classes and braces without expanding products.
  Shell and arbitrary external tools do not discover native file scopes.
  """
  alias Lemieux.Extensions.Workspace.Containment
  alias Lemieux.Harness
  alias Lemieux.Session
  alias Lemieux.Tools.Search.GlobPattern

  @namespace "lemieux.workspace_rules"

  @doc "Loads personal rules, then ancestor-to-nearer repository rules."
  @spec discover(roots :: [{Path.t(), Path.t(), atom()}], scope :: map()) ::
          {[map()], [String.t()]}
  def discover(roots, scope) do
    candidates = Enum.flat_map(roots, &candidates(&1, scope))
    {kept, overflow} = Enum.split(candidates, 64)

    notes =
      if overflow == [], do: [], else: ["Claude rules exceed 64 files; later files were skipped"]

    {rules, notes, _bytes} = Enum.reduce(kept, {[], notes, 0}, &load(&1, scope, &2))
    {Enum.reverse(rules), Enum.reverse(notes)}
  end

  defp candidates({directory, root, owner}, scope) do
    if File.dir?(directory) and permitted?(directory, owner, scope),
      do:
        directory
        |> Path.join("**/*.md")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(&{&1, root, owner}),
      else: []
  end

  defp permitted?(path, :repository, scope),
    do: match?({:ok, _real}, Containment.check(path, scope))

  defp permitted?(path, :personal, scope),
    do: is_nil(Containment.hidden(Containment.real_path(path), scope))

  defp load({path, root, owner}, scope, {rules, notes, bytes}) do
    with true <- permitted?(path, owner, scope),
         {:ok, stat} <- File.stat(path),
         true <- stat.size <= 32_768 and bytes + stat.size <= 131_072,
         {:ok, text} <- bounded_read(path),
         true <- bytes + byte_size(text) <= 131_072,
         true <- String.valid?(text),
         {:ok, attributes, body} <- frontmatter(text),
         {:ok, patterns} <- patterns(attributes) do
      digest = :crypto.hash(:sha256, path <> text) |> Base.encode16(case: :lower)

      rule = %{
        path: path,
        root: root,
        owner: owner,
        body: body,
        patterns: patterns,
        digest: digest
      }

      {[rule | rules], unknown_fields(path, attributes) ++ notes, bytes + byte_size(text)}
    else
      _invalid ->
        {rules,
         [
           "#{path}: rule skipped (invalid scope, unreadable, outside trust boundary, or size limit)"
           | notes
         ], bytes}
    end
  end

  defp bounded_read(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        data = IO.binread(file, 32_769)
        File.close(file)

        if is_binary(data) and byte_size(data) <= 32_768,
          do: {:ok, data},
          else: {:error, :file_limit}

      error ->
        error
    end
  end

  defp frontmatter("---\n" <> rest) do
    case String.split(rest, ~r/\r?\n---\r?\n/, parts: 2) do
      [yaml, body] ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, attributes} when is_map(attributes) -> {:ok, attributes, body}
          _invalid -> {:error, :frontmatter}
        end

      _invalid ->
        {:error, :frontmatter}
    end
  end

  defp frontmatter("---\r\n" <> rest), do: frontmatter("---\n" <> rest)
  defp frontmatter(text), do: {:ok, %{}, text}

  defp patterns(attributes) do
    values = Map.get(attributes, "paths", [])

    values =
      if is_binary(values),
        do: Regex.split(~r/,(?![^{]*})/, values) |> Enum.map(&String.trim/1),
        else: values

    if is_list(values) and length(values) <= 64, do: compile_all(values), else: {:error, :paths}
  end

  defp compile_all(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, compiled} ->
      case compile(value) do
        {:ok, pattern} -> {:cont, {:ok, compiled ++ [pattern]}}
        error -> {:halt, error}
      end
    end)
  end

  defp compile(value) when is_binary(value) and byte_size(value) in 1..1024 do
    if String.starts_with?(value, ["/", "!", "../"]) or ".." in Path.split(value),
      do: {:error, :absolute_or_parent_scope},
      else: GlobPattern.compile("./" <> value)
  end

  defp compile(_value), do: {:error, :pattern}

  defp unknown_fields(path, attributes) do
    case Map.keys(attributes) -- ["paths"] do
      [] ->
        []

      fields ->
        ["#{path}: rule frontmatter fields ignored: #{Enum.map_join(fields, ", ", &to_string/1)}"]
    end
  end

  @doc "Adds rule hooks while discovery owns current file contents."
  @spec attach(harness :: Harness.t(), rules :: [map()]) :: Harness.t()
  def attach(harness, []), do: harness

  def attach(harness, rules) do
    Harness.append_hooks(harness,
      prepare_next_turn: fn request, context -> prepare(request, context, rules) end,
      before_tool_call: fn call, context -> activate(call, context, rules) end
    )
  end

  @doc "Unscoped guidance and the scoped catalog for the workspace layer."
  @spec prompt(rules :: [map()]) :: String.t()
  def prompt(rules) do
    Enum.map_join(rules, "\n\n", fn rule ->
      if rule.patterns == [],
        do: guidance(rule),
        else:
          "Scoped rule #{rule.path}: #{Enum.map_join(rule.patterns, ", ", & &1.source)}. Use native file tools to load applicable guidance before editing. Shell and arbitrary external tools do not discover file scopes."
    end)
  end

  defp prepare(request, context, rules) do
    case Session.document(context.session, @namespace) do
      {:ok, document} ->
        active = active(document)

        text =
          rules
          |> Enum.filter(&(&1.patterns != [] and &1.digest in active))
          |> Enum.map_join("\n\n", &guidance/1)

        {:ok, %{request | system: Enum.join([request.system || "", text], "\n\n")}}

      _error ->
        {:deny, "Cannot reconstruct scoped workspace rules"}
    end
  end

  defp activate(call, context, rules) do
    paths = paths(call.arguments, context.cwd)
    matched = Enum.filter(rules, &matches?(&1, paths))
    if matched == [], do: :allow, else: activate_rules(context.session, matched, 2)
  end

  defp activate_rules(session, matched, attempts) do
    case Session.document(session, @namespace) do
      {:ok, document} ->
        commit(
          session,
          document,
          Enum.reject(matched, &(&1.digest in active(document))),
          matched,
          attempts
        )

      _error ->
        {:deny, "Cannot reconstruct scoped workspace rules"}
    end
  end

  defp commit(_session, _document, [], _matched, _attempts), do: :allow

  defp commit(session, document, new, matched, attempts) do
    value = %{
      "active" => Enum.uniq(active(document) ++ Enum.map(new, & &1.digest)) |> Enum.take(-64)
    }

    case Session.put_document(session, @namespace, document.revision, value) do
      {:ok, _document} ->
        {:deny,
         "Applicable workspace rules were loaded before this operation. Reconsider the call under the next request's rule context, then retry."}

      {:error, {:conflict, _revision}} when attempts > 1 ->
        activate_rules(session, matched, attempts - 1)

      _error ->
        {:deny, "Scoped rule activation could not be checkpointed"}
    end
  end

  defp active(%{value: %{"active" => active}}) when is_list(active), do: active
  defp active(_document), do: []
  defp guidance(rule), do: "Workspace rule #{rule.path}:\n" <> rule.body
  defp matches?(%{patterns: []}, _paths), do: false

  defp matches?(rule, paths) do
    Enum.any?(paths, fn path ->
      relative = Path.relative_to(path, rule.root)

      not String.starts_with?(relative, "../") and
        Enum.any?(rule.patterns, &GlobPattern.match?(&1, relative))
    end)
  end

  defp paths(arguments, cwd) do
    direct = if is_binary(arguments["path"]), do: [arguments["path"]], else: []
    patch = arguments["input"] || arguments["patch"]

    patches =
      if is_binary(patch),
        do:
          Regex.scan(~r/^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$/m, patch,
            capture: :all_but_first
          )
          |> List.flatten(),
        else: []

    Enum.map(direct ++ patches, &Path.expand(&1, cwd))
  end
end

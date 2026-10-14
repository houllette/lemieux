defmodule Lemieux.RepositoryContext.Elixir do
  @moduledoc """
  An offline, optional Elixir source indexer. Never compiles or evaluates code.

  The host explicitly supplies an environment, root and relative file manifest.
  No repository configuration, compiler task, dependency, macro or language
  server is executed. The parser encodes identifiers as strings so indexing
  arbitrary repositories cannot exhaust the VM's atom table.

  Definitions, syntactic calls and module dependencies carry source SHA-256
  digests and one-based lines. Parse errors become selected diagnostics. This
  is an approximate syntax index: aliases, imports, generated definitions,
  macros and dynamic dispatch are not resolved. For compiler semantics, supply
  a host-owned language-server adapter through `Lemieux.RepositoryContext.Source`.

  `build/4` accepts `:previous` for incremental parsing reuse, `:allow` for a
  path predicate, `:max_files` (default 1,000), `:max_items` (10,000), `:max_source_bytes` (4 MB),
  `:max_file_bytes` (500 KB) and `:timeout_ms` (2 s). Unchanged files are still
  read and hashed: modification times alone miss same-size edits. Deleted or
  denied files disappear from a rebuilt manifest. Retained build metrics
  distinguish reads, parses, reuse and partial coverage; no background cache
  or durable retrieval memory is created.
  """
  alias Lemieux.Environment
  alias Lemieux.RepositoryContext.Index
  alias Lemieux.RepositoryContext.Reader
  alias Lemieux.RepositoryContext.Worker

  @type metrics :: %{
          read_bytes: non_neg_integer(),
          parsed: non_neg_integer(),
          reused: non_neg_integer(),
          omitted: non_neg_integer(),
          elapsed_ms: non_neg_integer()
        }

  @doc "Builds a bounded snapshot from the host manifest, with optional parsing reuse."
  @spec build(
          environment :: Environment.t(),
          cwd :: Path.t(),
          paths :: Enumerable.t(),
          opts :: keyword()
        ) ::
          {:ok, Index.t(), metrics()} | {:error, atom()}
  def build(environment, cwd, paths, opts \\ []) do
    limits = limits!(opts)
    started = System.monotonic_time(:millisecond)
    context = %{cwd: cwd, environment: environment}

    repo = %{
      root: :session,
      environment: :session,
      allow: fn path, _ctx -> Keyword.get(opts, :allow, fn _ -> true end).(path) end
    }

    previous = Keyword.get(opts, :previous, %Index{})

    case Worker.run(
           fn -> build_index(repo, context, paths, previous, limits, started) end,
           limits.timeout_ms
         ) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp limits!(opts) do
    Map.new(
      [
        max_files: 1_000,
        max_items: 10_000,
        max_source_bytes: 4_000_000,
        max_file_bytes: 500_000,
        timeout_ms: 2_000
      ],
      fn {key, default} ->
        value = Keyword.get(opts, key, default)

        if not (is_integer(value) and value in 1..(default * 10)),
          do: raise(ArgumentError, "invalid #{key}")

        {key, value}
      end
    )
  end

  defp build_index(repo, context, paths, previous, limits, started) do
    initial = %{
      files: %{},
      examined: 0,
      item_count: 0,
      read_bytes: 0,
      parsed: 0,
      reused: 0,
      omitted: 0,
      complete?: true
    }

    state =
      paths
      |> Stream.take(limits.max_files + 1)
      |> Enum.reduce_while(initial, fn path, acc ->
        if acc.examined >= limits.max_files or acc.item_count >= limits.max_items or
             System.monotonic_time(:millisecond) - started >= limits.timeout_ms do
          {:halt, %{acc | complete?: false}}
        else
          {:cont,
           index_file(repo, context, path, previous, limits, %{acc | examined: acc.examined + 1})}
        end
      end)

    items =
      state.files
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {_path, file} -> file.items end)

    manifest =
      state.files
      |> Enum.map(fn {path, file} -> {path, file.digest} end)
      |> Enum.sort()

    revision =
      {"syntax-v1", manifest, items, state.complete?}
      |> :erlang.term_to_binary()
      |> Reader.digest()

    index = %{
      Index.new(items,
        revision: revision,
        complete?: state.complete?,
        limitations: ["syntax index only; aliases, macros and dynamic dispatch are unresolved"]
      )
      | files: state.files
    }

    metrics =
      state
      |> Map.take([:read_bytes, :parsed, :reused, :omitted])
      |> Map.put(:elapsed_ms, System.monotonic_time(:millisecond) - started)

    {:ok, index, metrics}
  end

  defp index_file(repo, context, path, previous, limits, state) do
    allowance = min(limits.max_file_bytes, limits.max_source_bytes - state.read_bytes)

    read =
      if allowance > 0,
        do: Reader.read(repo, context, path, allowance),
        else: {:error, :source_limit}

    case read do
      {:ok, text} ->
        parse_file(path, text, previous, limits, %{
          state
          | read_bytes: state.read_bytes + byte_size(text)
        })

      {:error, :source_limit} ->
        %{
          state
          | omitted: state.omitted + 1,
            complete?: false,
            read_bytes: state.read_bytes + max(0, allowance)
        }

      {:error, _reason} ->
        %{state | omitted: state.omitted + 1, complete?: false}
    end
  end

  defp parse_file(path, text, previous, limits, state) do
    digest = Reader.digest(text)
    analyzer = __MODULE__.module_info(:md5)

    case previous.files[path] do
      %{digest: ^digest, analyzer: ^analyzer, truncated?: false} = file ->
        keep_file(path, file, limits, %{state | reused: state.reused + 1})

      _missing_or_changed ->
        {items, complete?} = parse(text, path, digest)

        file = %{
          digest: digest,
          analyzer: analyzer,
          items: items,
          complete?: complete?,
          truncated?: false
        }

        keep_file(path, file, limits, %{state | parsed: state.parsed + 1})
    end
  end

  defp keep_file(path, file, limits, state) do
    items = Enum.take(file.items, limits.max_items - state.item_count)
    truncated? = length(items) < length(file.items)

    file = %{
      file
      | items: items,
        complete?: file.complete? and not truncated?,
        truncated?: truncated?
    }

    %{
      state
      | files: Map.put(state.files, path, file),
        item_count: state.item_count + length(items),
        complete?: state.complete? and file.complete?
    }
  end

  defp parse(text, path, digest) do
    case Code.string_to_quoted(text, static_atoms_encoder: fn name, _metadata -> {:ok, name} end) do
      {:ok, ast} ->
        {walk(ast, "", [], path, digest), true}

      {:error, {location, _error, _token}} ->
        line = Keyword.get(location, :line, 1)

        {[
           %{
             kind: "diagnostic",
             path: path,
             line: line,
             symbol: "parse_error",
             digest: digest,
             severity: "error",
             message: "Elixir syntax could not be parsed; semantic coverage is partial"
           }
         ], false}
    end
  end

  defp walk({"defmodule", meta, [name, body]}, parent, acc, path, digest) do
    module = module_name(name)

    module =
      if parent == "" or String.starts_with?(module, parent <> "."),
        do: module,
        else: parent <> "." <> module

    acc = add(acc, "definition", module, meta, parent, path, digest)
    walk(body, module, acc, path, digest)
  end

  defp walk({definition, meta, [head | body]}, module, acc, path, digest)
       when definition in ["def", "defp", "defmacro", "defmacrop"] do
    acc =
      case head(head) do
        {name, arity} ->
          add(acc, "definition", qualify(module, name, arity), meta, module, path, digest)

        nil ->
          acc
      end

    walk(body, module, acc, path, digest)
  end

  defp walk({{:., _dot_meta, [target, function]}, meta, args}, module, acc, path, digest)
       when is_binary(function) and is_list(args) do
    target = module_name(target)

    acc =
      if target == "",
        do: acc,
        else:
          add(
            acc,
            "reference",
            qualify(target, function, length(args)),
            meta,
            module,
            path,
            digest
          )

    acc =
      if target == "", do: acc, else: add(acc, "dependency", target, meta, module, path, digest)

    walk(args, module, acc, path, digest)
  end

  defp walk({:__aliases__, meta, _parts} = node, module, acc, path, digest),
    do: add(acc, "dependency", module_name(node), meta, module, path, digest)

  defp walk({name, meta, args}, module, acc, path, digest)
       when is_binary(name) and is_list(args) do
    acc =
      if name in ~w(alias import require use quote unquote defstruct defexception),
        do: acc,
        else:
          add(acc, "reference", qualify(module, name, length(args)), meta, module, path, digest)

    walk(args, module, acc, path, digest)
  end

  defp walk(node, module, acc, path, digest) when is_tuple(node),
    do: walk(Tuple.to_list(node), module, acc, path, digest)

  defp walk(nodes, module, acc, path, digest) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &walk(&1, module, &2, path, digest))

  defp walk(_node, _module, acc, _path, _digest), do: acc

  defp head({:when, _meta, [head | _guards]}), do: head(head)
  defp head({name, _meta, args}) when is_binary(name) and is_list(args), do: {name, length(args)}
  defp head({name, _meta, nil}) when is_binary(name), do: {name, 0}
  defp head(_head), do: nil
  defp module_name({:__aliases__, _meta, parts}), do: Enum.join(parts, ".")
  defp module_name(_node), do: ""
  defp qualify("", name, arity), do: "#{name}/#{arity}"
  defp qualify(module, name, arity), do: "#{module}.#{name}/#{arity}"

  defp add(acc, kind, symbol, meta, container, path, digest) do
    [
      %{
        kind: kind,
        path: path,
        line: Keyword.get(meta, :line, 1),
        symbol: symbol,
        container: if(container == "", do: nil, else: container),
        digest: digest
      }
      | acc
    ]
  end
end

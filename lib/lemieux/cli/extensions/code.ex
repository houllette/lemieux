defmodule Lemieux.CLI.Extensions.Code do
  @moduledoc false

  # Code ownership is VM-wide. Check every carried module, including modules
  # that have not been loaded yet, before putting any new directory on the
  # path. Checking only the extension's entry module let two otherwise valid
  # bundles silently run whichever dependency happened to load first.
  @spec install(paths :: [Path.t()], name :: String.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def install(paths, name) do
    with {:ok, beams} <- read(paths),
         :ok <- defines(beams, name),
         :ok <- compatible(beams) do
      Enum.each(paths, &Code.prepend_path/1)

      case load(beams) do
        :ok ->
          {:ok, Enum.sort(Enum.map(beams, fn {module, _, _, md5} -> {inspect(module), md5} end))}

        {:error, _} = error ->
          error
      end
    end
  end

  defp read(paths) do
    paths
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.beam")))
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, beams} ->
      with {:ok, %{type: :regular}} <- File.lstat(path),
           {:ok, bytes} <- File.read(path),
           {:ok, {module, md5}} <- :beam_lib.md5(bytes),
           true <- Path.basename(path) == "#{module}.beam" do
        {:cont, {:ok, [{module, path, bytes, Base.encode16(md5, case: :lower)} | beams]}}
      else
        _ ->
          {:halt, {:error, "#{path} must be a real beam file named for its module (no symlink)"}}
      end
    end)
  end

  defp defines(beams, name) do
    if Enum.any?(beams, fn {module, _, _, _} -> inspect(module) == name end),
      do: :ok,
      else: {:error, "#{name} is not defined by the extension's beams"}
  end

  defp compatible(beams) do
    Enum.reduce_while(beams, {:ok, %{}}, fn {module, path, _bytes, digest}, {:ok, seen} ->
      existing = Map.get_lazy(seen, module, fn -> existing_digest(module) end)

      if existing in [nil, digest] do
        {:cont, {:ok, Map.put(seen, module, digest)}}
      else
        {:halt,
         {:error,
          "#{inspect(module)} in #{path} conflicts with code already available in this VM; restart with compatible extension dependencies"}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp existing_digest(module) do
    case :code.is_loaded(module) do
      {:file, _} -> module.module_info(:md5) |> Base.encode16(case: :lower)
      false -> path_digest(:code.which(module))
    end
  end

  defp path_digest(:non_existing), do: nil

  defp path_digest(path) when is_list(path) do
    case :beam_lib.md5(path) do
      {:ok, {_, md5}} -> Base.encode16(md5, case: :lower)
      _ -> :unreadable
    end
  end

  defp path_digest(_), do: :reserved

  defp load(beams) do
    Enum.reduce_while(beams, :ok, fn {module, path, bytes, _}, :ok ->
      # Loading from the bytes we verified pins lazy dependencies too. Merely
      # reserving their names would still let a later path change replace them.
      result =
        if :code.is_loaded(module) == false,
          do: :code.load_binary(module, String.to_charlist(path), bytes),
          else: {:module, module}

      case result do
        {:module, ^module} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "could not load #{inspect(module)} from #{path}: #{inspect(reason)}"}}
      end
    end)
  end

  @spec compile(path :: Path.t(), source :: String.t(), module :: module()) ::
          {:ok, map()} | {:error, String.t()}
  def compile(path, source, module) do
    # Scripts are trusted Elixir, not a sandbox. The returned compiler list is
    # the authority for what this file defined; ensure_loaded alone accepted
    # an empty file claiming somebody else's already-loaded extension.
    declarations = source |> Code.string_to_quoted!(file: path) |> declarations(nil)
    conflict = Enum.find([module | declarations], &(:code.which(&1) != :non_existing))

    if conflict do
      {:error, "#{inspect(conflict)} is already available in this VM; restart to load #{path}"}
    else
      compiled = Code.compile_string(source, path)

      if List.keymember?(compiled, module, 0),
        do: {:ok, Map.new(compiled, fn {mod, _beam} -> {mod, mod.module_info(:md5)} end)},
        else: {:error, "#{inspect(module)} is not defined by #{path}"}
    end
  rescue
    error in [CompileError, SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      {:error, "#{path} did not compile: #{Exception.message(error)}"}
  end

  # Literal module declarations cover ordinary extension scripts, including
  # nested helper modules. This catches accidental collisions before compile
  # can replace code. Trusted Elixir can still invoke the code server itself;
  # this preflight is not a sandbox for hostile programs.
  defp declarations({:defmodule, _, [{:__aliases__, _, parts}, body]}, parent) do
    module =
      case parts do
        [Elixir | rest] -> Module.concat(rest)
        _ -> if parent, do: Module.concat([parent | parts]), else: Module.concat(parts)
      end

    [module | declarations(body, module)]
  end

  defp declarations(tuple, parent) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> declarations(parent)

  defp declarations(list, parent) when is_list(list),
    do: Enum.flat_map(list, &declarations(&1, parent))

  defp declarations(_, _), do: []
end

defmodule Lmx.Update.Callbacks do
  @moduledoc """
  Rejects retained local functions owned by modules about to be replaced.
  Soft purge only protects direct execution references on current OTP; stored
  anonymous functions can become badfun even on the first hot update.

  Inspect the screen, its attached session and persistent terms before loading.
  These terms are never logged. Other processes and ETS remain the release
  author's compatibility-review responsibility; this guard is not a proof over
  arbitrary user code. Failure to inspect a live session requires restart.
  """

  @doc "Checks the live host state and shared persistent callbacks."
  @spec safe?(tui :: pid(), modules :: [String.t()]) :: boolean()
  def safe?(tui, modules) do
    %{user_state: state} = :sys.get_state(tui, 2_000)

    safe_term?(state, modules) and safe_session?(state.session, modules) and
      safe_term?(:persistent_term.get(), modules)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp safe_session?(nil, _modules), do: true
  defp safe_session?(session, modules), do: safe_term?(:sys.get_state(session, 2_000), modules)

  @doc "External function captures resolve current code; local functions retain code identity."
  @spec safe_term?(term :: term(), modules :: [String.t()]) :: boolean()
  def safe_term?(term, modules), do: safe_term?(term, modules, 64)

  defp safe_term?(_term, _modules, 0), do: false

  defp safe_term?(fun, modules, depth) when is_function(fun) do
    {:module, module} = :erlang.fun_info(fun, :module)
    {:type, type} = :erlang.fun_info(fun, :type)
    {:env, env} = :erlang.fun_info(fun, :env)

    (type == :external or Atom.to_string(module) not in modules) and
      safe_term?(env, modules, depth - 1)
  end

  defp safe_term?(map, modules, depth) when is_map(map),
    do: map |> Map.to_list() |> safe_term?(modules, depth - 1)

  defp safe_term?(tuple, modules, depth) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> safe_term?(modules, depth - 1)

  defp safe_term?([head | tail], modules, depth),
    do: safe_term?(head, modules, depth - 1) and safe_term?(tail, modules, depth)

  defp safe_term?(_term, _modules, _depth), do: true
end

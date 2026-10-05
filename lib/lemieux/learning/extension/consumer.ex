defmodule Lemieux.Learning.Extension.Consumer do
  @moduledoc false

  alias Lemieux.Agent
  alias Lemieux.Learning.Extension.Build
  alias Lemieux.Learning.Extension.Tree

  @spec run(args :: [String.t()]) :: :ok
  def run([root, input_path, output_path]) do
    {:ok, receipt} = Tree.read(Path.join(root, "build.json"))
    {:ok, _build} = Build.open(root, receipt["sha256"])
    2 = :erlang.system_info(:schedulers_online)
    source = Path.join(root, "source")
    {:ok, manifest} = Tree.read(Path.join(source, "lemieux-extension.json"))
    {:ok, profile} = Tree.read(Path.join(root, "profile.json"))
    {:ok, input} = Tree.read(input_path)
    files = Path.wildcard(Path.join(source, "lib/**/*.ex"))
    {:ok, _modules, []} = Kernel.ParallelCompiler.compile(files, warnings_as_errors: true)
    module = String.to_existing_atom("Elixir." <> manifest["module"])
    {:ok, options, ^profile} = module.configure(profile)
    true = Keyword.keyword?(options)
    input = %{prompt: input["prompt"], cwd: input["cwd"], timeout_ms: input["timeout_ms"]}
    result = Agent.run(module, input, budget(options, profile))
    :ok = Tree.write(output_path, envelope(result))
  end

  defp budget(options, %{"execution" => "scripted"}), do: options

  defp budget(options, %{"options" => %{"usage_mode" => "quota", "max_requests" => maximum}}) do
    session = Keyword.get(options, :session_options, [])
    existing = session[:max_requests]
    cap = if is_integer(existing) and existing > 0, do: min(existing, maximum), else: maximum
    Keyword.put(options, :session_options, Keyword.put(session, :max_requests, cap))
  end

  defp budget(options, %{"options" => %{"max_cost_usd" => cap}}) do
    session = Keyword.get(options, :session_options, [])

    maximum =
      case session[:max_cost_usd] do
        existing when is_number(existing) and existing > 0 -> min(existing, cap)
        _other -> cap
      end

    Keyword.put(options, :session_options, Keyword.put(session, :max_cost_usd, maximum))
  end

  defp envelope({:ok, observation}), do: %{"ok" => true, "observation" => observation}

  defp envelope({:error, reason, observation}),
    do: %{"ok" => false, "error" => inspect(reason), "observation" => observation}

  defp envelope({:error, reason}), do: %{"ok" => false, "error" => inspect(reason)}
end

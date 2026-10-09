defmodule Lemieux.CLI.Startup do
  @moduledoc false

  # Host-only progress: no renderer or callback is recorded in a harness or
  # transcript. Callers can name additional work without a fixed stage registry.
  @spec step(
          opts :: keyword(),
          id :: atom() | String.t(),
          text :: String.t(),
          work :: (-> result)
        ) :: result
        when result: var
  def step(opts, id, text, work) do
    observe(opts, id, text, "busy")
    result = work.()
    observe(opts, id, text, if(match?({:error, _}, result), do: "fail", else: "ok"))
    result
  end

  @spec extension(opts :: keyword(), extension :: Lemieux.Extension.spec(), work :: (-> result)) ::
          result
        when result: var
  def extension(opts, {module, _options}, work), do: extension(opts, module, work)

  def extension(opts, module, work),
    do: step(opts, "extension:#{inspect(module)}", "Initialize #{inspect(module)}", work)

  @spec assemble_extension(
          harness :: Lemieux.Harness.t(),
          extension :: Lemieux.Extension.spec(),
          opts :: keyword()
        ) ::
          {:ok, Lemieux.Harness.t()} | {:error, term()}
  def assemble_extension(harness, extension, opts),
    do: extension(opts, extension, fn -> Lemieux.Harness.assemble(harness, [extension]) end)

  defp observe(opts, id, text, status) do
    if callback = opts[:startup_step], do: callback.(id, text, status)
  end
end

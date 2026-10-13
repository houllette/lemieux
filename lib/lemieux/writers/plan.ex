defmodule Lemieux.Writers.Plan do
  @moduledoc """
  A host-approved writer brief with explicit file ownership and tool permissions.

  Paths are exact files or directory prefixes ending in `/`. Globs are not
  authority: an ambiguous pattern makes overlapping ownership hard to detect.
  A brief cannot name Git metadata or escape its workspace.
  """
  @enforce_keys [:id, :task, :paths, :tools]
  defstruct [:id, :task, :paths, :tools, max_requests: 100]

  @type t :: %__MODULE__{
          id: String.t(),
          task: String.t(),
          paths: [String.t()],
          tools: [String.t()],
          max_requests: pos_integer()
        }

  @doc "Builds a bounded brief; invalid or ambiguous authority raises."
  @spec new(opts :: keyword()) :: t()
  def new(opts) do
    plan = struct!(__MODULE__, opts)
    unless valid?(plan), do: raise(ArgumentError, "invalid writer brief")
    %{plan | paths: Enum.sort(Enum.uniq(plan.paths)), tools: Enum.uniq(plan.tools)}
  end

  @doc "Checks a brief without broadening its scope."
  @spec valid?(plan :: term()) :: boolean()
  def valid?(%__MODULE__{} = plan) do
    id?(plan.id) and text?(plan.task, 32_768) and paths?(plan.paths) and
      tools?(plan.tools) and positive?(plan.max_requests)
  end

  def valid?(_plan), do: false

  @doc "Whether a relative file is owned by this brief."
  @spec owns?(plan :: t(), path :: String.t()) :: boolean()
  def owns?(plan, path) do
    path?(path) and Enum.any?(plan.paths, &matches?(&1, path))
  end

  @doc "Whether two briefs claim any of the same paths."
  @spec overlaps?(left :: t(), right :: t()) :: boolean()
  def overlaps?(left, right) do
    Enum.any?(left.paths, fn a ->
      Enum.any?(right.paths, &collides?(a, &1))
    end)
  end

  defp collides?(left, right) do
    left = left |> String.trim_trailing("/") |> String.downcase()
    right = right |> String.trim_trailing("/") |> String.downcase()

    left == right or String.starts_with?(left, right <> "/") or
      String.starts_with?(right, left <> "/")
  end

  @doc false
  @spec path?(path :: term()) :: boolean()
  def path?(path) when is_binary(path) and byte_size(path) in 1..4096 do
    parts = path |> String.trim_trailing("/") |> String.split("/")

    Path.type(path) == :relative and not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(parts, &(&1 not in ["", ".", "..", ".git"] and String.downcase(&1) != ".git"))
  end

  def path?(_path), do: false

  defp matches?(scope, path) do
    scope == path or (String.ends_with?(scope, "/") and String.starts_with?(path, scope))
  end

  defp id?(id) when is_binary(id), do: Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, id)
  defp id?(_id), do: false
  defp text?(text, limit) when is_binary(text), do: byte_size(text) in 1..limit
  defp text?(_text, _limit), do: false

  defp paths?(paths) when is_list(paths),
    do: length(paths) in 1..100 and Enum.all?(paths, &path?/1)

  defp paths?(_paths), do: false

  defp tools?(tools) when is_list(tools),
    do: length(tools) in 1..32 and Enum.all?(tools, &text?(&1, 128))

  defp tools?(_tools), do: false
  defp positive?(value), do: is_integer(value) and value > 0
end

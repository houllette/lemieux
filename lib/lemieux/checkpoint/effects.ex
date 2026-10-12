defmodule Lemieux.Checkpoint.Effects do
  @moduledoc false

  alias Lemieux.Checkpoint.Files
  alias Lemieux.Checkpoint.Git
  alias Lemieux.Checkpoint.Store
  alias Lemieux.Checkpoint.Window

  # Compare each call's own window. A turn-wide or HEAD-to-worktree diff
  # attributes the person's existing edits to the agent and rechecks read-only
  # commands. Unknown snapshots remain unknown, never an empty change list.
  @spec read(session :: Path.t(), call_ids :: [String.t()]) :: map()
  def read(session, call_ids) do
    wanted = MapSet.new(call_ids)

    session
    |> Store.turns()
    |> Enum.flat_map(fn turn ->
      directory = Store.turn_dir(session, turn)
      file_effects(directory, wanted) ++ command_effects(directory, session, wanted)
    end)
    |> Map.new(&{&1["call_id"], &1})
  end

  defp file_effects(directory, wanted) do
    afters =
      directory
      |> Path.join("after")
      |> Store.all_json()
      |> Map.new(&{{&1["call_id"], &1["cwd"], &1["path"]}, &1["after"]})

    directory
    |> Path.join("captures")
    |> Store.all_json()
    |> Enum.filter(&MapSet.member?(wanted, &1["call_id"]))
    |> Enum.group_by(& &1["call_id"])
    |> Enum.map(fn {id, captures} ->
      changed =
        Enum.reject(captures, fn capture ->
          later = afters[{id, capture["cwd"], capture["path"]}]
          Files.same?(capture["before"], later)
        end)

      %{
        "call_id" => id,
        "status" => if(changed == [], do: "unchanged", else: "changed"),
        "paths" => changed |> Enum.map(& &1["path"]) |> Enum.uniq() |> Enum.take(2000)
      }
    end)
  end

  defp command_effects(directory, session, wanted) do
    directory
    |> Window.all()
    |> Enum.filter(&MapSet.member?(wanted, &1["call_id"]))
    |> Enum.map(&command_effect(&1, session))
  end

  defp command_effect(
         %{"before" => %{"tree" => before}, "after" => %{"tree" => later}} = window,
         session
       ) do
    case Git.changed(window["root"], before, later, scratch: Store.scratch(session)) do
      {:ok, changes} ->
        unsaved? = window["before"]["unsaved"] != window["after"]["unsaved"]

        %{
          "call_id" => window["call_id"],
          "status" => if(changes != [] or unsaved?, do: "changed", else: "unchanged"),
          "paths" => Enum.take(Enum.map(changes, &elem(&1, 1)), 2000),
          "before_tree" => before,
          "after_tree" => later,
          "root" => window["root"],
          "unsaved_changes" => unsaved?
        }

      {:error, _reason} ->
        unknown(window)
    end
  end

  defp command_effect(window, _session), do: unknown(window)

  defp unknown(window),
    do: %{"call_id" => window["call_id"], "status" => "unknown", "paths" => []}
end

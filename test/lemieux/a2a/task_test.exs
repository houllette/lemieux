defmodule Lemieux.A2A.TaskTest do
  use ExUnit.Case, async: true

  alias Lemieux.A2A.Task

  defp task(fields \\ []), do: struct!(%Task{id: "task-1"}, fields)

  describe "the three kinds of state" do
    test "every state is exactly one of active, interrupted or terminal" do
      for state <- Task.states() do
        answers = [Task.active?(state), Task.interrupted?(state), Task.terminal?(state)]

        assert Enum.count(answers, & &1) == 1, "#{state} answered #{inspect(answers)}"
      end
    end

    test "all eight of the protocol's states are covered" do
      assert length(Task.states()) == 8
    end

    test "waiting on somebody is not the same as being finished" do
      assert Task.interrupted?(:input_required)
      refute Task.terminal?(:input_required)

      assert Task.interrupted?(:auth_required)
      refute Task.terminal?(:auth_required)
    end

    test "and the four endings really are endings" do
      for state <- [:completed, :failed, :canceled, :rejected] do
        assert Task.terminal?(state)
      end
    end
  end

  describe "transition/3" do
    test "moves an active task along, carrying a message" do
      assert {:ok, working} = Task.transition(task(), :working, "reading the file")

      assert working.state == :working
      assert working.message == "reading the file"
    end

    test "lets an interrupted task carry on, because that is what answering does" do
      assert {:ok, working} = Task.transition(task(state: :input_required), :working)

      assert working.state == :working
    end

    test "refuses to move a task that has already ended" do
      assert {:error, message} = Task.transition(task(state: :completed), :failed)

      assert message =~ "already completed"
      assert message =~ "final"
    end

    test "and refuses every ending, not just the contradictory one" do
      for to <- [:working, :completed, :canceled, :input_required] do
        assert {:error, _message} = Task.transition(task(state: :rejected), to)
      end
    end

    test "refuses a state the protocol does not define" do
      assert {:error, message} = Task.transition(task(), :nearly_done)

      assert message =~ "not a task state"
    end

    test "clears an interrupted message when a transition gives none" do
      task = task(state: :working, message: "still going")

      assert {:ok, completed} = Task.transition(task, :completed)
      assert completed.message == nil
    end
  end

  describe "from_finish/1" do
    test "an ordinary end is a completion" do
      assert Task.from_finish(:stop) == :completed
    end

    test "a cancellation is its own ending, not a failure" do
      assert Task.from_finish(:cancelled) == :canceled
    end

    # The one that would be tempting to get wrong: both of these stop the work
    # early, and a peer told `completed` would treat a half-finished job as
    # done and build on it.
    test "running out of turns, or of progress, is a failure" do
      assert Task.from_finish(:max_turns) == :failed
      assert Task.from_finish(:no_progress) == :failed
    end

    test "and anything unrecognised fails rather than claiming success" do
      assert Task.from_finish(:something_new) == :failed
    end

    test "every reason a session can finish with maps somewhere sensible" do
      for reason <- [:stop, :cancelled, :max_turns, :no_progress] do
        assert Task.from_finish(reason) in Task.states()
      end
    end
  end

  describe "the wire spelling" do
    test "round-trips every state" do
      for state <- Task.states() do
        assert {:ok, ^state} = state |> Task.to_wire() |> Task.from_wire()
      end
    end

    test "uses the protocol's enum names" do
      assert Task.to_wire(:input_required) == "TASK_STATE_INPUT_REQUIRED"
      assert Task.to_wire(:completed) == "TASK_STATE_COMPLETED"
    end

    test "reads the older hyphenated spelling too, rather than refusing a peer" do
      assert Task.from_wire("input-required") == {:ok, :input_required}
      assert Task.from_wire("completed") == {:ok, :completed}
    end

    test "and says so when it does not recognise one" do
      assert Task.from_wire("TASK_STATE_NAPPING") == :error
    end
  end
end

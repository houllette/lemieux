defmodule Lemieux.TUI.ActivityTest do
  @moduledoc """
  The sentence a phase turns into, with no terminal anywhere near it.

  `Lemieux.TUI.ViewTest` covers the wiring — which session event moves the screen
  into which phase — through a rendered transcript. What is here is the
  wording, which is the part that runs on a machine that never installed the
  optional NIF and the part a host's own status line reads.
  """

  use ExUnit.Case, async: true

  alias Lemieux.TUI.Activity

  defp turn(fields \\ []) do
    Enum.into(fields, %{
      busy?: true,
      label: "Deking",
      elapsed: 12,
      frame: 0,
      phase: nil,
      delegation: nil
    })
  end

  defp phase(kind, detail, for_seconds \\ 3, elapsed_ms \\ 3_000),
    do: %{kind: kind, detail: detail, for: for_seconds, elapsed_ms: elapsed_ms}

  describe "the line as a whole" do
    test "says nothing between turns" do
      assert Activity.line(turn(busy?: false)) == nil
    end

    test "is the label and the clock when there is no phase yet" do
      assert Activity.line(turn()) == "Deking (12s)"
    end

    # The label leads because it is the thing that changes once per turn: it is
    # how a glance back tells a new turn from the old one still running.
    test "puts the phase after the label" do
      assert Activity.line(turn(phase: phase(:thinking, nil, 40))) ==
               "Deking (12s) · thinking (40s)"
    end
  end

  describe "what each wait is called" do
    test "waiting for a response" do
      assert Activity.phase(turn(phase: phase(:waiting, nil, 6))) ==
               "waiting for the model (6s)"
    end

    test "reading a fan-out's results, until the first delta ends it" do
      reading = turn(phase: phase(:waiting, nil, 6), delegation: %{count: 2, bytes: 20_480})

      assert Activity.phase(reading) ==
               "reading 2 read-only investigations (20.0 KB) · waiting for the model (6s)"

      assert Activity.phase(%{reading | delegation: %{count: 1, bytes: 512}}) ==
               "reading 1 read-only investigation (512 B) · waiting for the model (6s)"
    end

    # A long silent write is the wait this was built for: a session on
    # 2026-09-18 spent two and a half minutes on one 35 KB call behind
    # a label that said only `Processing`, which looks exactly like a hang.
    test "composing a tool call names what it is writing and how far in" do
      detail = %{name: "write", target: "tmp/analysis.md", bytes: 18_636}

      assert Activity.phase(turn(phase: phase(:composing, detail))) ==
               "composing write tmp/analysis.md (18.2 KB)"
    end

    test "composing without a target says only the call" do
      detail = %{name: "a tool call", target: nil, bytes: 40}

      assert Activity.phase(turn(phase: phase(:composing, detail))) ==
               "composing a tool call (40 B)"
    end

    # On the person, not the model: a row still reading `running bash` while
    # a hook held the call would have somebody watching for output that was
    # waiting on them.
    test "waiting for the person to approve a parked call" do
      assert Activity.phase(turn(phase: phase(:approval, %{name: "bash"}, 9))) ==
               "waiting for your approval of bash (9s)"
    end

    test "running a tool, answering, and delegating" do
      assert Activity.phase(turn(phase: phase(:tool, %{name: "bash"}, 120))) ==
               "running bash (2m)"

      assert Activity.phase(turn(phase: phase(:answering, nil))) == "answering"

      assert Activity.phase(turn(phase: phase(:delegating, %{running: 2}, 240))) ==
               "2 read-only investigations running (4m)"
    end

    # The countdown subtracts from the delay the provider was given, so it
    # reaches zero as the retry goes out rather than sitting on its first
    # value until something else happens.
    test "a retry counts down from the delay it was given" do
      detail = %{attempt: 2, max: 2, delay_ms: 8_000, kind: "provider error"}

      assert Activity.phase(turn(phase: phase(:retrying, detail, 2, 2_000))) ==
               "provider error, retrying in 6s (2/2)"

      assert Activity.phase(turn(phase: phase(:retrying, detail, 9, 9_000))) ==
               "provider error, retrying in 0s (2/2)"
    end

    test "says nothing between phases" do
      assert Activity.phase(turn()) == nil
    end

    # New kinds get added, and a stale `case` that fell through to a label
    # would describe the previous wait to somebody waiting on this one.
    test "says nothing about a kind it does not recognise" do
      assert Activity.phase(turn(phase: phase(:teleporting, nil))) == nil
      assert Activity.line(turn(phase: phase(:teleporting, nil))) == "Deking (12s)"
    end
  end

  describe "the spinner" do
    # Driven by the frame counter rather than a clock, so it moves exactly
    # when the screen is redrawn.
    test "turns with the frame and wraps around" do
      glyphs = Enum.map(0..9, &Activity.spinner/1)

      assert length(Enum.uniq(glyphs)) == 10
      assert Activity.spinner(10) == Activity.spinner(0)
      assert Activity.spinner(23) == Activity.spinner(3)
    end

    # One cell, so the text beside it never shuffles — which is what the
    # trailing dots this replaced had to be padded to avoid.
    test "is always one column wide" do
      for frame <- 0..9, do: assert(String.length(Activity.spinner(frame)) == 1)
    end
  end

  describe "the clock and the scale" do
    test "seconds, then minutes, then hours" do
      assert Activity.duration(0) == "0s"
      assert Activity.duration(59) == "59s"
      assert Activity.duration(60) == "1m"
      assert Activity.duration(3_599) == "59m"
      assert Activity.duration(7_560) == "2hr 6m"
    end

    test "bytes below a kilobyte, kilobytes above it" do
      assert Activity.bytes(0) == "0 B"
      assert Activity.bytes(1_023) == "1023 B"
      assert Activity.bytes(1_024) == "1.0 KB"
      assert Activity.bytes(18_636) == "18.2 KB"
    end

    test "a fan-out of one is not a fan-out of ones" do
      assert Activity.investigations(1) == "1 read-only investigation"
      assert Activity.investigations(3) == "3 read-only investigations"
    end
  end
end

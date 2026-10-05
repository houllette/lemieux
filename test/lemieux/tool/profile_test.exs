defmodule Lemieux.Tool.ProfileTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tool.Profile
  alias Lemieux.Tools

  describe "decision/2" do
    # `allowed?/2` answers whether, and the caller then has to guess why. A
    # host that shares one session between people denies `elixir` on purpose
    # and `ask_user` as a consequence of the same setting, and those are
    # different things to be told.
    test "names why a shared profile refuses each tool" do
      profile = Profile.new(%{"id" => "host", "allow" => "all", "shared" => true})

      assert Profile.decision(profile, Tools.Eval) == {:deny, :default_off_shared}
      assert Profile.decision(profile, Tools.AskUser) == {:deny, :no_human_channel}
      assert Profile.decision(profile, Tools.Read) == :allow
    end

    test "names an allowlist that simply omits the tool" do
      profile = Profile.new(%{"id" => "host", "allow" => ["read"]})

      assert Profile.decision(profile, Tools.Bash) == {:deny, :not_allowlisted}
      assert Profile.decision(profile, Tools.Read) == :allow
    end

    # A shared host that names the tool has said what it meant, and that
    # outranks the default.
    test "an explicit allowlist entry beats the shared default" do
      profile = Profile.new(%{"id" => "host", "allow" => ["elixir"], "shared" => true})

      assert Profile.decision(profile, Tools.Eval) == :allow
    end

    test "the permissive default refuses nothing" do
      for tool <- [Tools.Read, Tools.Bash, Tools.Eval, Tools.AskUser] do
        assert Profile.decision(Profile.new(nil), tool) == :allow
      end
    end

    test "allowed?/2 agrees with it" do
      profile = Profile.new(%{"id" => "host", "allow" => "all", "shared" => true})

      for tool <- [Tools.Read, Tools.Bash, Tools.Eval, Tools.AskUser] do
        assert Profile.allowed?(profile, tool) == (Profile.decision(profile, tool) == :allow)
      end
    end
  end
end

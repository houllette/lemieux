defmodule LemieuxTest.FrozenRuntime do
  @moduledoc false

  # These fixtures execute only Agent.run plus the frozen consumer's integrity
  # checks. Copying the entire harness (including TUI/provider code) into every
  # build multiplies filesystem traversal and hashing without exercising it.
  # The builder/security integration tests still freeze the complete runtime.
  @modules [
    Lemieux.Agent,
    Lemieux.Learning.Extension.Export,
    Lemieux.Learning.Extension.Build,
    Lemieux.Learning.Extension.Consumer,
    Lemieux.Learning.Extension.Tree,
    Lemieux.Contract,
    Lemieux.JSON
  ]

  @spec create() :: [Path.t()]
  def create do
    root =
      Path.join(
        System.tmp_dir!(),
        "lmx-frozen-runtime-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    ebin = Path.join(root, "lemieux/ebin")
    File.mkdir_p!(ebin)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)

    for module <- @modules do
      file = "#{module}.beam"
      # :code.which/1 returns :cover_compiled under mix test --cover. The
      # independent consumer needs the original on-disk BEAMs in either mode.
      File.cp!(Application.app_dir(:lemieux, "ebin/#{file}"), Path.join(ebin, file))
    end

    [ebin]
  end
end

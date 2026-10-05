defmodule LemieuxBuilderExtension do
  @moduledoc "The first-party builder exercised as an ordinary Mix extension."
  @behaviour Lemieux.Agent

  @impl Lemieux.Agent
  def configure(profile), do: Lemieux.Learning.Builder.configure(profile)

  @impl Lemieux.Agent
  def run(input, opts), do: Lemieux.Learning.Builder.run(input, opts)
end

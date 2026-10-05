defmodule Lemieux.MCP.RemoteTool do
  @moduledoc """
  A tool that lives on an MCP server rather than in this repository.

  `Lemieux.Tool` is a behaviour, and a module cannot be written at runtime for
  something a server described a moment ago — so a remote tool is a struct
  instead, and `Lemieux.Tools` dispatches on the two shapes. That is the whole
  of the difference: once resolved, an MCP tool goes through the same hooks,
  the same approval, the same transcript entry and the same error handling as
  `read` or `bash`.

  ## Why the name is qualified

  Two servers may each offer `search`. The specification tells clients that
  aggregate tools from several servers to disambiguate them, and this is that
  strategy: the model is offered `github__search`, and the call is routed back
  to the server the name names. Tool names may contain dots but not
  underscores by convention, which is why a double underscore separates them.

  ## Why the name is sometimes rewritten

  MCP allows a tool name almost anything — dots, slashes, spaces — and a
  server name is whatever somebody typed into a configuration. Provider APIs
  do not: a tool name has to match `^[a-zA-Z_][a-zA-Z0-9_]*(-[a-zA-Z0-9_]+)*$`
  and fit in 64 characters, and `req_llm` raises on one that does not. Offered
  as-is, a single server exposing `files.read` failed *every* request of the
  session with `provider_crashed`, including the ones that never touched MCP.

  So a name that is already valid is offered unchanged — which keeps every
  name that ever worked stable across upgrades and resumes — and one that is
  not is rewritten into the allowed alphabet, shortened to fit, and given a
  six-character hash of the original. The hash is what makes the rewrite
  safe: `files.read` and `files_read` from one server would otherwise both
  become `files_read`, and a call for one would be routed to the other. Routing
  never parses the offered name back apart; the struct carries its server and
  its unqualified name, and `Lemieux.Tool.name/1` is what a model's call is
  matched against.
  """

  @enforce_keys [:name, :server, :description, :schema]
  defstruct [
    :name,
    :server,
    :description,
    :schema,
    :title,
    :client,
    :output_schema,
    :protocol_version,
    :server_info,
    :offered_name,
    annotations: %{},
    meta: %{},
    content_types: ["text/plain"]
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          server: String.t(),
          description: String.t(),
          schema: map(),
          title: String.t() | nil,
          client: pid() | nil,
          output_schema: map() | nil,
          protocol_version: String.t() | nil,
          server_info: map() | nil,
          offered_name: String.t() | nil,
          annotations: map(),
          meta: map(),
          content_types: [String.t()]
        }

  @separator "__"
  @max_length 64
  @hash_length 6
  @valid ~r/\A[a-zA-Z_][a-zA-Z0-9_]*(-[a-zA-Z0-9_]+)*\z/

  @doc """
  The name the model is offered, which carries the server it belongs to.

  Always a name a provider accepts: see the module documentation for how an
  unusable one is rewritten. `assign_names/1` may have settled it already, when
  two tools in one list would otherwise have been offered under one name.
  """
  @spec qualified_name(tool :: t()) :: String.t()
  def qualified_name(%__MODULE__{offered_name: name}) when is_binary(name), do: name
  def qualified_name(%__MODULE__{server: server, name: name}), do: qualify(server, name)

  @doc """
  The provider-safe name for `name` on `server`, before any collision is
  settled: `server__name` when that is valid, else a rewrite of it with a
  hash of the original. Also what a host uses to name a server's prompts.
  """
  @spec qualify(server :: String.t(), name :: String.t()) :: String.t()
  def qualify(server, name) when is_binary(server) and is_binary(name), do: offered(server, name)

  @doc """
  The separator between a server's name and a tool's.
  """
  @spec separator() :: String.t()
  def separator, do: @separator

  @doc """
  Whether `name` is one every provider accepts as a tool name.
  """
  @spec valid_name?(name :: String.t()) :: boolean()
  def valid_name?(name) when is_binary(name),
    do: byte_size(name) <= @max_length and Regex.match?(@valid, name)

  @doc """
  Settles the offered name of every tool in `tools`, and says which changed.

  Each tool keeps the name `qualified_name/1` would give it, unless two tools
  in the list land on the same one — possible only when a rewritten name
  happens to equal a name that was valid to begin with, or when two servers'
  names collide — in which case every tool in that group gets a hash of its
  own server and name. The result is deterministic, so a resumed session
  offers the same names the transcript recorded.

  A server that lists the same tool twice has it offered once: two catalog
  entries under one name are a catalog `Lemieux.Tool.validate_all/1` refuses,
  and refusing it would cost every other server its tools too.

  Returns the tools, with `:offered_name` set, and one sentence per tool whose
  offered name differs from `server__name`, for a host to show.
  """
  @spec assign_names(tools :: [t()]) :: {[t()], [String.t()]}
  def assign_names(tools) when is_list(tools) do
    named =
      tools
      |> Enum.uniq_by(&{&1.server, &1.name})
      |> Enum.map(&%{&1 | offered_name: qualified_name(%{&1 | offered_name: nil})})

    counts = Enum.frequencies_by(named, & &1.offered_name)

    settled =
      Enum.map(named, fn tool ->
        if counts[tool.offered_name] > 1,
          do: %{tool | offered_name: with_hash(tool.offered_name, raw(tool) <> "\0collision")},
          else: tool
      end)

    notices =
      for tool <- settled, tool.offered_name != raw(tool) do
        "The MCP tool #{inspect(tool.name)} from #{tool.server} is offered to the model as " <>
          "#{tool.offered_name}: provider tool names allow only letters, digits, underscores " <>
          "and hyphens, up to #{@max_length} characters."
      end

    {settled, notices}
  end

  defp raw(%__MODULE__{server: server, name: name}), do: server <> @separator <> name

  # A valid name is returned unchanged; anything else is rewritten into the
  # allowed alphabet and always given a hash of the original, so two different
  # originals can never be offered under one rewritten name.
  defp offered(server, name) do
    raw = server <> @separator <> name

    if valid_name?(raw), do: raw, else: raw |> sanitize() |> with_hash(raw)
  end

  defp sanitize(raw) do
    raw
    |> String.replace(~r/[^A-Za-z0-9_-]/u, "_")
    |> String.replace(~r/-{2,}/, "-")
    |> leading()
  end

  defp leading(<<first, _rest::binary>> = name) when first in ?0..?9 or first == ?-,
    do: "_" <> name

  defp leading(""), do: "_"
  defp leading(name), do: name

  # The hash is appended after an underscore, which also repairs a name that
  # sanitising or truncation left ending in a hyphen: `-_` is allowed, a
  # trailing `-` is not.
  defp with_hash(name, source) do
    suffix = "_" <> hash(source)
    room = @max_length - byte_size(suffix)

    binary_part(name, 0, min(byte_size(name), room)) <> suffix
  end

  defp hash(source) do
    :sha256
    |> :crypto.hash(source)
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_length)
  end
end

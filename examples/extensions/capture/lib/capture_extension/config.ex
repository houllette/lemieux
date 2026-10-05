defmodule CaptureExtension.Config do
  @moduledoc """
  What the capture hook watches for, and where it writes.

  Every value has a default so that `CaptureExtension.hooks/1` with no
  options is a working configuration. The two pattern lists are literal
  strings, matched at word boundaries: a verification pattern is found
  anywhere inside a `bash` command (`cd sub && mix test` matches `mix test`;
  `mix tests` does not), and a correction pattern is matched at the start of
  a user message (`No, use make` matches `no`; `Now add tests` does not).
  Word boundaries are what make the short default corrections usable at all.

  Directories are resolved here except `drafts_dir`, which is relative to
  the session's working directory because that is where the person who
  ran the session will look for what it left behind.
  """

  alias Lemieux.CLI.Options

  @mebibyte 1_048_576

  @default_verification_patterns [
    "mix test",
    "tests/run.sh",
    "make test",
    "make check",
    "npm test",
    "pytest",
    "cargo test",
    "go test"
  ]

  @default_correction_patterns [
    "no",
    "wrong",
    "that's not",
    "undo",
    "revert",
    "not what I asked",
    "you broke"
  ]

  @default_skip_dirs [".git", "_build", "deps", "node_modules"]

  @type t :: %__MODULE__{
          verification_patterns: [String.t()],
          correction_patterns: [String.t()],
          verification_regexes: [{String.t(), Regex.t()}],
          correction_regexes: [{String.t(), Regex.t()}],
          drafts_dir: Path.t(),
          sessions_dir: Path.t(),
          feedback_dir: Path.t(),
          max_file_bytes: pos_integer(),
          max_total_bytes: pos_integer(),
          skip_dirs: [String.t()],
          tenant_id: String.t(),
          store: Lemieux.Store.t() | nil,
          feedback_store: Lemieux.Feedback.Store.t() | nil
        }

  defstruct verification_patterns: @default_verification_patterns,
            correction_patterns: @default_correction_patterns,
            verification_regexes: [],
            correction_regexes: [],
            drafts_dir: ".lmx/drafts",
            sessions_dir: nil,
            feedback_dir: nil,
            max_file_bytes: @mebibyte,
            max_total_bytes: 16 * @mebibyte,
            skip_dirs: @default_skip_dirs,
            tenant_id: "local",
            store: nil,
            feedback_store: nil

  @option_names ~w(verification_patterns correction_patterns drafts_dir sessions_dir feedback_dir
                   max_file_bytes max_total_bytes skip_dirs tenant_id store feedback_store)a

  @doc "The option keys `new/1` understands, so a caller can split them from its own."
  @spec option_names() :: [atom()]
  def option_names, do: @option_names

  @doc "The verification commands watched when nothing else is configured."
  @spec default_verification_patterns() :: [String.t()]
  def default_verification_patterns, do: @default_verification_patterns

  @doc "The message openings treated as corrections when nothing else is configured."
  @spec default_correction_patterns() :: [String.t()]
  def default_correction_patterns, do: @default_correction_patterns

  @doc """
  Builds a configuration from options, validating each.

  Options: `:verification_patterns`, `:correction_patterns`, `:drafts_dir`,
  `:sessions_dir` (default: `lmx`'s own), `:feedback_dir` (default: the
  `feedback` directory beside the sessions directory, as `lmx feedback`
  uses), `:max_file_bytes`, `:max_total_bytes`, `:skip_dirs`, `:tenant_id`,
  and the `:store` / `:feedback_store` seams a host or test may inject.
  """
  @spec new(opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts) when is_list(opts) do
    sessions_dir = Keyword.get(opts, :sessions_dir) || Options.default_sessions_dir()

    config = %__MODULE__{
      verification_patterns:
        Keyword.get(opts, :verification_patterns, @default_verification_patterns),
      correction_patterns: Keyword.get(opts, :correction_patterns, @default_correction_patterns),
      drafts_dir: Keyword.get(opts, :drafts_dir, ".lmx/drafts"),
      sessions_dir: sessions_dir,
      feedback_dir:
        Keyword.get(opts, :feedback_dir) || Path.join(Path.dirname(sessions_dir), "feedback"),
      max_file_bytes: Keyword.get(opts, :max_file_bytes, @mebibyte),
      max_total_bytes: Keyword.get(opts, :max_total_bytes, 16 * @mebibyte),
      skip_dirs: Keyword.get(opts, :skip_dirs, @default_skip_dirs),
      tenant_id: Keyword.get(opts, :tenant_id, "local"),
      store: Keyword.get(opts, :store),
      feedback_store: Keyword.get(opts, :feedback_store)
    }

    with :ok <- patterns(config.verification_patterns, :verification_patterns),
         :ok <- patterns(config.correction_patterns, :correction_patterns),
         :ok <- strings(config.skip_dirs, :skip_dirs),
         :ok <- positive(config.max_file_bytes, :max_file_bytes),
         :ok <- positive(config.max_total_bytes, :max_total_bytes),
         :ok <- path(config.drafts_dir, :drafts_dir),
         :ok <- path(config.sessions_dir, :sessions_dir),
         :ok <- path(config.feedback_dir, :feedback_dir),
         :ok <- path(config.tenant_id, :tenant_id) do
      {:ok,
       %{
         config
         | verification_regexes: Enum.map(config.verification_patterns, &contained/1),
           correction_regexes: Enum.map(config.correction_patterns, &leading/1)
       }}
    end
  end

  @doc "Like `new/1`, raising `ArgumentError` on an invalid option."
  @spec new!(opts :: keyword()) :: t()
  def new!(opts) when is_list(opts) do
    case new(opts) do
      {:ok, config} -> config
      {:error, message} -> raise ArgumentError, "capture extension: " <> message
    end
  end

  @doc """
  Builds a configuration from environment variables, for the command hook.

  `LMX_SESSIONS_DIR` is `lmx`'s own. The capture-specific names are
  `LMX_CAPTURE_DRAFTS_DIR`, `LMX_CAPTURE_FEEDBACK_DIR`,
  `LMX_CAPTURE_VERIFICATION_PATTERNS` and `LMX_CAPTURE_CORRECTION_PATTERNS`
  (`|`-separated), `LMX_CAPTURE_MAX_FILE_BYTES`, `LMX_CAPTURE_MAX_TOTAL_BYTES`
  and `LMX_CAPTURE_TENANT_ID`. The map is a parameter rather than
  `System.get_env/0` so a test can describe an environment without owning
  the process's.
  """
  @spec from_env(env :: %{optional(String.t()) => String.t()}) ::
          {:ok, t()} | {:error, String.t()}
  def from_env(env) when is_map(env) do
    with {:ok, max_file} <- integer(env, "LMX_CAPTURE_MAX_FILE_BYTES"),
         {:ok, max_total} <- integer(env, "LMX_CAPTURE_MAX_TOTAL_BYTES") do
      []
      |> put_present(:sessions_dir, env["LMX_SESSIONS_DIR"])
      |> put_present(:drafts_dir, env["LMX_CAPTURE_DRAFTS_DIR"])
      |> put_present(:feedback_dir, env["LMX_CAPTURE_FEEDBACK_DIR"])
      |> put_present(:tenant_id, env["LMX_CAPTURE_TENANT_ID"])
      |> put_present(:verification_patterns, split(env["LMX_CAPTURE_VERIFICATION_PATTERNS"]))
      |> put_present(:correction_patterns, split(env["LMX_CAPTURE_CORRECTION_PATTERNS"]))
      |> put_present(:max_file_bytes, max_file)
      |> put_present(:max_total_bytes, max_total)
      |> new()
    end
  end

  # A verification command is found anywhere in the command line, as whole
  # tokens: `mix test` inside `cd sub && mix test`, `pytest` inside
  # `python -m pytest`, `tests/run.sh` after `./`, but never `mix test`
  # inside `mix tests` or `pytest` inside `pytest-cov`.
  defp contained(pattern) do
    {pattern, ~r/(?<![A-Za-z0-9_-])#{Regex.escape(pattern)}(?![A-Za-z0-9_-])/i}
  end

  # A correction opens the message, after any whitespace, and ends at a word
  # boundary: `No.` and `no, use make` are corrections, `Now add tests` is not.
  defp leading(pattern) do
    {pattern, ~r/\A\s*#{Regex.escape(pattern)}(?![A-Za-z0-9_])/i}
  end

  defp patterns(value, name) do
    if is_list(value) and value != [] and Enum.all?(value, &nonempty?/1),
      do: :ok,
      else: {:error, "#{name} must be a non-empty list of non-empty strings"}
  end

  defp strings(value, name) do
    if is_list(value) and Enum.all?(value, &nonempty?/1),
      do: :ok,
      else: {:error, "#{name} must be a list of non-empty strings"}
  end

  defp positive(value, _name) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, name), do: {:error, "#{name} must be a positive integer"}

  defp path(value, _name) when is_binary(value) and value != "", do: :ok
  defp path(_value, name), do: {:error, "#{name} must be a non-empty string"}

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp integer(env, name) do
    case Map.get(env, name) do
      nil ->
        {:ok, nil}

      value ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} when integer > 0 -> {:ok, integer}
          _invalid -> {:error, "#{name} must be a positive integer"}
        end
    end
  end

  defp split(nil), do: nil
  defp split(value), do: value |> String.split("|") |> Enum.map(&String.trim/1)

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)
end

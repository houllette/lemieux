# Slash choice generation is separate from the editor and frame callback. The
# caller supplies the current text and cached catalog/reference data; this module
# does not read the filesystem or mutate the native textarea during a render.
if Code.ensure_loaded?(ExRatatui.Widgets.SlashCommands) do
  defmodule Lemieux.TUI.CompletionSources do
    @moduledoc "Produces slash, model, tool and path choices from TUI state snapshots."

    alias ExRatatui.Widgets.SlashCommands
    alias ExRatatui.Widgets.SlashCommands.Command
    alias Lemieux.CLI.SessionIndex
    alias Lemieux.Conversation
    alias Lemieux.Conversation.Command, as: ConversationCommand
    alias Lemieux.Extensions.Workspace.Skill
    alias Lemieux.Reference
    alias Lemieux.TUI.ModelChoices
    alias Lemieux.TUI.Theme

    # An `@` at a word boundary opens the file picker, and the reference runs to the
    # end of the line — what is completed is always what the caret sits in. The word
    # boundary stops a menu opening over `someone@example.com`, the same rule
    # `Lemieux.Reference` parses a submitted prompt with. The quoted alternative is
    # what lets the picker descend into a directory whose name has a space in it.
    @path_reference ~r/(?:^|\s)(@(?:"[^"\n]*"?|\S*))$/

    # A directory of five thousand generated files should not become a list
    # rebuilt behind the bounded menu on every keystroke.
    @path_limit 50

    @doc "Returns the completion choices for the current editor text and cached picker context."
    @spec matches(String.t(), map()) :: [map()]
    def matches(value, state) do
      # The command's own name and its argument are two questions, and
      # answering both in one `cond` put this function over Credo's
      # complexity bar as the command list grew.
      if Regex.match?(~r/^\s*\/[^\s]*$/, value),
        do: command_completions(state, value),
        else: argument_completions(state, value)
    end

    # One clause per command rather than one `cond` over all of them: the
    # command list keeps growing, and a `cond` that grows with it is a single
    # function Credo eventually fails the build over. The prefixes also read
    # as what they are this way.
    defp argument_completions(state, "/provider " <> _rest = value),
      do: value_completions(state.catalog.providers, value, "/provider ")

    defp argument_completions(state, "/model " <> _rest = value),
      do: ModelChoices.completions(state.catalog.model_choices, value, state.model_tab)

    # Effort levels run from least to most, which is the only order in which
    # `minimal` next to `high` means anything.
    defp argument_completions(state, "/effort " <> _rest = value),
      do: offered_in_order(state.catalog.efforts, value, "/effort ")

    # A fixed list, not a catalog: what this screen can draw is decided here
    # rather than discovered, so there is nothing to merge in.
    defp argument_completions(state, "/color " <> _rest = value),
      do: accent_completions(state, value, "/color ")

    defp argument_completions(state, "/colour " <> _rest = value),
      do: accent_completions(state, value, "/colour ")

    defp argument_completions(state, "/theme " <> _rest = value),
      do: value_completions(Theme.names(state.themes), value, "/theme ")

    defp argument_completions(state, "/tools " <> _rest = value),
      do: tool_completions(state, state.tool_statuses, value)

    defp argument_completions(_state, "/mcp " <> _rest), do: []

    defp argument_completions(state, "/resume " <> _rest = value),
      do: resume_completions(state, value)

    # A command with a `completions/2` of its own — `/approve`, or a host's —
    # is asked before the `@` picker, which is what every other argument
    # falls through to.
    defp argument_completions(state, value) do
      case command_completions_for(state, value) do
        [] -> path_completions(state, value)
        completions -> completions
      end
    end

    defp command_completions_for(state, "/" <> rest = value) do
      with [name, typed] <- String.split(rest, ~r/\s+/, parts: 2),
           module when not is_nil(module) <-
             ConversationCommand.find(state.conversation.commands, name),
           true <- Code.ensure_loaded?(module) and function_exported?(module, :completions, 2) do
        value_completions(module.completions(typed, state.conversation), value, "/#{name} ")
      else
        _none -> []
      end
    end

    defp command_completions_for(_state, _value), do: []

    defp accent_completions(state, value, prefix),
      do: value_completions(["default" | state.accent_names], value, prefix)

    defp tool_completions(state, statuses, "/tools enable " <> _rest = value),
      do: tool_name_completions(statuses, value, "/tools enable ", state.command_policy)

    defp tool_completions(state, statuses, "/tools disable " <> _rest = value),
      do: tool_name_completions(statuses, value, "/tools disable ", state.command_policy)

    defp tool_completions(state, _statuses, value),
      do: tool_action_completions(value, state.command_policy)

    defp command_completions(state, value) do
      {:command, prefix} = SlashCommands.parse(value)
      definitions = command_definitions(state)
      by_name = Map.new(definitions, &{&1.name, &1})

      definitions
      |> Enum.map(&struct!(Command, Map.take(&1, [:name, :aliases, :description])))
      |> SlashCommands.match_commands(prefix)
      # One list rather than the built-ins followed by the skills. A skill is a
      # command to whoever typed the slash, and a second alphabet starting
      # halfway down the menu is worse than no alphabet at all.
      |> Enum.sort_by(&String.downcase(&1.name))
      |> Enum.map(fn command ->
        accepts_arguments? =
          Map.fetch!(by_name, command.name).accepts_arguments? and command.name != "mcp"

        suffix = if accepts_arguments?, do: " ", else: ""

        %{
          label: "/#{command.name} — #{command.description}",
          value: "/#{command.name}#{suffix}",
          opens_arguments?: accepts_arguments?
        }
      end)
    end

    # The conversation's registry — host commands included — and then the
    # skills, which are data rather than modules and merge after: a skill
    # can never take a command's name.
    @doc "Lists visible slash commands and skills under the host command policy."
    @spec command_definitions(map()) :: [map()]
    def command_definitions(state) do
      builtins = Conversation.commands(state.conversation, state.command_policy)
      reserved = MapSet.new(Enum.flat_map(builtins, &[&1.name | &1.aliases]))

      skills =
        state.skills
        |> Enum.map(fn skill ->
          %{
            name: Skill.qualified_name(skill),
            aliases: [],
            description: skill_description(skill),
            accepts_arguments?: true
          }
        end)
        |> Enum.reject(&MapSet.member?(reserved, &1.name))

      builtins ++ skills
    end

    # Every other menu whose list is a set of names — commands, skills,
    # providers, tools, servers, colours — is alphabetical. A catalog arrives in
    # whatever order a provider's API, a config file or a `@commands` literal
    # happened to put it in; that is an order nobody can predict and therefore
    # nobody can scan, and what somebody does know is the first letter of the
    # thing they are looking for.
    #
    # Three lists keep an order of their own, because theirs already says
    # something alphabetical would throw away: `/effort` runs from least to
    # most, `/tools` leads with the action that only reads, and
    # `/resume` is newest first. `/model` uses preferred choices, lifecycle
    # status and release dates rather than putting GPT-4 ahead of GPT-6.
    defp value_completions(values, value, prefix) do
      query = value |> String.replace_prefix(prefix, "") |> String.downcase() |> String.trim()

      values
      |> ranked(query)
      |> Enum.map(&%{label: &1, value: prefix <> &1})
    end

    # The same menu with the list left as it was handed over.
    defp offered_in_order(values, value, prefix) do
      query = value |> String.replace_prefix(prefix, "") |> String.downcase() |> String.trim()

      values
      |> Enum.filter(&String.contains?(String.downcase(&1), query))
      |> Enum.map(&%{label: &1, value: prefix <> &1})
    end

    # Alphabetical, except that a name already typed in full outranks the
    # longer ones merely containing it. These menus match on substring and
    # Enter takes the highlighted row, so without this `/color gray` and Enter
    # sets the accent to `dark_gray` — a command that did something other than
    # what it says. Case-insensitive throughout, so a capital does not sort a
    # name above every lowercase one.
    defp ranked(values, query) do
      values
      |> Enum.filter(&String.contains?(String.downcase(&1), query))
      |> Enum.sort_by(fn value ->
        down = String.downcase(value)

        cond do
          down == query -> {0, down}
          String.starts_with?(down, query) -> {1, down}
          true -> {2, down}
        end
      end)
    end

    defp resume_completions(state, "/resume " <> query) do
      query = query |> String.downcase() |> String.trim()

      state.resume.sessions
      |> Enum.reject(&(&1.id == state.id))
      |> Enum.filter(fn session ->
        String.contains?(String.downcase(SessionIndex.label(session)), query)
      end)
      # The shorthand rather than the id, so what Tab leaves on the line is
      # also what a person can write down and type again next week.
      |> Enum.map(
        &%{label: SessionIndex.label(&1), value: "/resume #{SessionIndex.shorthand(&1)}"}
      )
    end

    # Relative to the session's working directory, because that is what the
    # session resolves a reference against. Reads nothing: the listing was
    # taken when the reference last named a different directory, by `edited/1`,
    # which is on the key path rather than the render path.
    defp path_completions(%{references: %{cwd: nil}}, _value), do: []

    defp path_completions(state, value) do
      case typed_path(value) do
        {kind, path} -> offered(state, value, path, kind)
        nil -> []
      end
    end

    # What path the caret sits in, and how it got there: an `@` reference or a
    # command argument. One function, because `listed/1` reads a directory from the
    # same text this offers completions from, and the two disagreeing is a menu
    # listing one directory against another's query.
    @doc "Identifies the reference or path argument currently being typed."
    @spec typed_path(String.t()) :: {:reference | :argument, String.t()} | nil
    def typed_path(value) do
      case Regex.run(@path_reference, value, capture: :all_but_first) do
        [reference] -> {:reference, reference}
        nil -> command_path(value)
      end
    end

    @doc """
    What a typed `@` reference searches for across every file, or `nil`
    when it should list a directory instead: nothing typed yet, or a path
    ending in `/`, which asks to look inside it.
    """
    @spec fuzzy_query(String.t()) :: String.t() | nil
    def fuzzy_query(reference) do
      query =
        reference
        |> String.replace_prefix("@", "")
        |> String.trim_leading(~s("))
        |> String.trim_trailing(~s("))

      if query == "" or String.ends_with?(query, "/"), do: nil, else: query
    end

    @doc "Returns the directory part of a typed path or reference."
    @spec directory(String.t()) :: String.t()
    def directory(path), do: path |> split_reference() |> elem(0)

    defp command_path("/mcp add " <> path), do: {:argument, path}
    defp command_path(_value), do: nil

    # The fuzzy matches `Lemieux.TUI.Composer` ranked for this very text win
    # over the directory listing: they include that directory's files and
    # every other file that fits, and the resources connected MCP servers
    # offer. See `Lemieux.TUI.FileIndex` and `Lemieux.TUI.ResourceIndex`.
    defp offered(%{references: %{fuzzy: %{query: path} = fuzzy}} = state, value, path, :reference) do
      head = String.replace_suffix(value, path, "")

      files =
        Enum.map(
          fuzzy.matches,
          &%{label: &1, value: head <> Reference.render(&1) <> " ", submit?: false}
        )

      resources =
        Enum.map(
          Map.get(fuzzy, :resources, []),
          &%{label: resource_label(&1), value: head <> &1.reference <> " ", submit?: false}
        )

      case fuzzy_offers(path, files, resources) do
        [] -> listing(state, value, path, :reference)
        offers -> offers
      end
    end

    defp offered(state, value, path, kind), do: listing(state, value, path, kind)

    # A colon already typed is somebody reaching for a server's resource, so
    # those come first; otherwise the files do, as before resources existed.
    defp fuzzy_offers(path, files, resources) do
      if String.contains?(path, ":"), do: resources ++ files, else: files ++ resources
    end

    defp resource_label(%{label: label, name: name}) when is_binary(name) and name != "",
      do: label <> " — " <> name

    defp resource_label(%{label: label}), do: label

    defp listing(state, value, path, kind) do
      {directory, query} = split_reference(path)

      if state.references.directory == directory do
        head = String.replace_suffix(value, path, "")

        state.references.entries
        |> Enum.filter(&offerable?(&1.name, query))
        |> Enum.take(@path_limit)
        |> Enum.map(&path_completion(&1, directory, head, kind))
      else
        []
      end
    end

    # Prefix rather than the substring match the other sources use: a path is typed
    # left to right, and `@ex` matching every file with an `ex` anywhere in it
    # buries the one being typed. Dotfiles stay hidden until a dot is typed, for the
    # reason a shell hides them.
    defp offerable?(name, "" = _query), do: not String.starts_with?(name, ".")

    defp offerable?(name, query),
      do: String.starts_with?(String.downcase(name), String.downcase(query))

    defp path_completion(%{name: name, type: :directory}, directory, head, kind) do
      %{
        label: name <> "/",
        # The trailing slash goes inside the quotes when there are quotes, so
        # what lands on the line is one reference rather than a quoted name
        # with a stray separator after it.
        value: head <> rendered_path(joined(directory, name) <> "/", kind),
        # Keeps the menu open so a second Tab descends into it rather than
        # sending a half-written path.
        opens_arguments?: true
      }
    end

    defp path_completion(%{name: name}, directory, head, kind),
      do: %{
        label: name,
        value: head <> rendered_path(joined(directory, name), kind) <> " ",
        submit?: kind == :argument
      }

    # A prompt's reference needs its `@` and its quoting; a command's argument
    # is the rest of the line and needs neither — `/mcp add @"x.json"` is not
    # a path `Lemieux.MCP.Config` can open.
    defp rendered_path(path, :reference), do: Reference.render(path)
    defp rendered_path(path, :argument), do: path

    defp split_reference(~s(@") <> rest),
      do: rest |> String.trim_trailing(~s(")) |> split_path()

    defp split_reference("@" <> rest), do: split_path(rest)

    # A command argument arrives without the sigil the clauses above strip.
    defp split_reference(path), do: split_path(path)

    defp split_path(path) do
      case String.split(path, "/") do
        [query] -> {"", query}
        parts -> {parts |> Enum.drop(-1) |> Enum.join("/"), List.last(parts)}
      end
    end

    defp joined("", name), do: name
    defp joined(directory, name), do: directory <> "/" <> name

    defp tool_action_completions(value, command_policy) do
      query = value |> String.replace_prefix("/tools ", "") |> String.trim() |> String.downcase()

      [
        {"list", :tools_status},
        {"enable", {:enable_tools, ["NAME"]}},
        {"disable", {:disable_tools, ["NAME"]}}
      ]
      |> Enum.filter(fn {_label, action} ->
        Conversation.command_decision(command_policy, action) == :allow
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&String.contains?(&1, query))
      |> Enum.map(fn
        action when action in ["enable", "disable"] ->
          %{
            label: action,
            value: "/tools #{action} ",
            opens_arguments?: true
          }

        action ->
          %{label: action, value: "/tools #{action}"}
      end)
    end

    defp tool_name_completions(statuses, value, prefix, command_policy) do
      rest = String.replace_prefix(value, prefix, "")
      parts = String.split(rest, ~r/\s+/, trim: true)

      {selected, query} =
        if String.ends_with?(rest, " ") do
          {parts, ""}
        else
          {Enum.drop(parts, -1), List.last(parts) || ""}
        end

      selected_names = selected
      selected = MapSet.new(selected_names)
      enabled? = prefix == "/tools disable "

      value_prefix =
        case selected_names do
          [] -> prefix
          names -> prefix <> Enum.join(names, " ") <> " "
        end

      statuses
      |> Enum.filter(
        &tool_completion?(
          &1,
          enabled?,
          selected,
          selected_names,
          command_policy
        )
      )
      |> Enum.map(& &1.name)
      |> ranked(String.downcase(query))
      |> Enum.map(&%{label: &1, value: value_prefix <> &1})
    end

    defp tool_completion?(status, enabled?, selected, selected_names, command_policy) do
      allowed? = enabled? or Map.get(status, :allowed?, true)
      action = if enabled?, do: :disable_tools, else: :enable_tools
      command = {action, selected_names ++ [status.name]}

      status.enabled? == enabled? and allowed? and
        not MapSet.member?(selected, status.name) and
        Conversation.command_decision(command_policy, command) == :allow
    end

    defp skill_description(%Skill{argument_hint: nil, description: description}), do: description

    defp skill_description(%Skill{argument_hint: hint, description: description}),
      do: "#{hint} — #{description}"
  end
end

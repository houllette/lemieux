# First embedded agent

This complete program starts a supervised session, sends one prompt, checks
its result and cleans up. It uses a scripted provider, so it needs no key,
network, terminal UI, web framework or database. Then it swaps in a real
model.

> **Requirements:** Elixir 1.19 or newer on Erlang/OTP 27 or newer. A real
> model needs one provider's API key, or a local model in Ollama.

## Add the library

Add Lemieux to your dependencies and run `mix deps.get`:

```elixir
def deps do
  [{:lemieux, "~> 0.8"}]
end
```

The terminal UI's native dependency is optional, and a library user does not
get it. To try unreleased changes, depend on the repository instead,
`{:lemieux, github: "houllette/lemieux"}`, or on a local checkout,
`{:lemieux, path: "/absolute/path/to/lemieux"}`.

Adding the dependency starts no Lemieux processes. Its own dependencies are
ordinary OTP applications that start with yours, and one of them matters
here: `req_llm`, which makes the model calls, loads a `.env` file from the
current working directory when it starts, and runs any `$(...)` command in
it. If your application may start in a directory you do not trust, turn that
off in `config/config.exs`, as the installed `lmx` does:

```elixir
config :req_llm, load_dotenv: false
```

## Run a session

Save this as `first_session.exs`, then run `mix run first_session.exs`. In a
Lemieux checkout, `mise exec -- mix run examples/first_session.exs` runs the
checked-in version of this script.

<!-- executable-tutorial -->
```elixir
# From the repository root: mix run examples/first_session.exs
# Also runs unchanged in an application with a Lemieux dependency.
alias Lemieux.Providers.Scripted

directory = Path.join(System.tmp_dir!(), "lemieux-first-#{System.unique_integer([:positive])}")
{:ok, supervisor} = Lemieux.Supervisor.start_link(name: FirstSession.Agents)
provider = Scripted.new([Scripted.complete("Hello from Lemieux")])

try do
  # Starts a session, sends the prompt, waits for the answer, stops the session.
  {:ok, result} =
    Lemieux.run("Say hello",
      supervisor: FirstSession.Agents,
      provider: provider,
      store: Lemieux.Store.JSONL.new(directory),
      model: "test:model",
      tools: [],
      max_requests: 1
    )

  :stop = result.stop_reason
  "Hello from Lemieux" = result.text
  1 = length(Scripted.requests(provider))
  IO.puts(result.text)
after
  Supervisor.stop(supervisor)
  File.rm_rf!(directory)
end
```
<!-- /executable-tutorial -->

Expected output: `Hello from Lemieux`. The scripted provider supplies the
model's answers, while the real session, supervision, events and transcript
storage run as they always do. The match assertions fail if the answer or the
number of requests changes.

`Lemieux.run/2` is one prompt in a session of its own. To keep a session and
prompt it again, start it with `Lemieux.start_session/1` and call
`Lemieux.Session.await/3` for each prompt. It returns the same result: the
answer's `text`, the `stop_reason`, the prompt's `usage` and the `entries` it
wrote.

`Lemieux.run/2` and `Lemieux.start_session/1` raise an `ArgumentError` that
says what is missing: no runtime mounted under `:supervisor`, no `:provider`
or `:store`, or a new session without a `:model`. `Lemieux.resume_session/1`
returns `{:error, :not_found}` for an id no transcript has, and raises the
same `ArgumentError` for a transcript it found when nothing is mounted.

## Use a real provider

Set the provider's key in your environment (here `ANTHROPIC_API_KEY`), save
this as `real_session.exs` in your application, and run
`mix run real_session.exs`:

```elixir
{:ok, _runtime} = Lemieux.Supervisor.start_link(name: RealSession.Agents)

{:ok, result} =
  Lemieux.run("Read mix.exs and say in one sentence what this project is.",
    supervisor: RealSession.Agents,
    provider: Lemieux.Providers.ReqLLM.new(),
    store: Lemieux.Store.JSONL.new("sessions"),
    model: "anthropic:claude-sonnet-5",
    tools: Lemieux.Tools.default(except: ["write", "edit", "bash"]),
    max_requests: 5
  )

IO.puts(result.text)
```

The model reads `mix.exs` with the `read` tool and answers. Any `provider:model`
specification ReqLLM knows works in `model:`, with that provider's key;
`lmx help models` lists the ones `lmx` recommends. `ollama:NAME` runs a local
model, which Ollama must serve with a long enough context window:
[Use a local model](providers.md#use-a-local-model) shows how to set one, and
[Models served by Ollama](embedding.md#models-served-by-ollama) says what the
provider does differently for local models. Keep a request limit:
`max_requests` counts every request the session makes, across resumes.

The transcript stays in `sessions/`, so passing `resume: result.session_id` to
another `Lemieux.run/2` continues the same conversation. `result.entries` is
everything this prompt wrote.

`tools:` decides what the model may do. `[]` gives it nothing; the example
keeps only `read`. `Lemieux.Tools.default()` adds `write`, `edit` and `bash`,
with the authority described in [Security](../SECURITY.md#threat-model). A
`cwd:` option confines the file tools to that directory by path, but it is
not a shell sandbox.

## Put it in your application

Mount the runtime in your supervision tree instead of starting and stopping it
around each call:

```elixir
# lib/my_app/application.ex
children = [
  # ...
  {Lemieux.Supervisor, name: MyApp.Agents}
]
```

Then pass `supervisor: MyApp.Agents` to `Lemieux.run/2` or
`Lemieux.start_session/1`. Two settings in `config/config.exs` are worth
making at the same time:

```elixir
# Do not load ./.env when req_llm starts (see "Add the library").
config :req_llm, load_dotenv: false

# Size the shared connection pool for the model streams you run at once,
# sessions plus delegated children, so Lemieux never has to resize it.
config :req_llm, stream_pool_size: 16
```

Supply a durable store and your current policy for each session. Your
application owns credentials, execution environments, process lifetimes and
isolation. By default `bash` inherits your application's whole environment;
`environment: Lemieux.Environment.Local.new(credentials: {:scrub, []})`
withholds variables whose names contain `KEY`, `TOKEN`, `SECRET`, `PASSWORD`
or `PASSWD`. In an OTP release, that environment is the release's own, with
its Erlang runtime first on `PATH`, and an Elixir project's `mix test` run
through it stops with `cannot get bootfile`. To give commands the environment
your release was started with instead, have its launcher record that
environment, then call `Lemieux.Environment.Inherited.put/1` once at boot with
the differences: the original `PATH`, and `nil` for `BINDIR`, `ROOTDIR`, `EMU`
and `PROGNAME` ([Decide what tools may see](embedding.md#5-decide-what-tools-may-see)
shows the call). Lemieux has no application start callback of its own.

## Next steps

Continue with [the embedding reference](embedding.md) for lifecycle, events,
persistence and host testing. Follow [Customizing Lemieux](customization.md)
to choose the right seam, then [Your first extension](first-extension.md) to
add a tested tool. The
[package-consumer example](https://github.com/houllette/lemieux/blob/main/test/package_consumer/lib/lemieux_package_consumer.ex)
shows a complete host using the public API.

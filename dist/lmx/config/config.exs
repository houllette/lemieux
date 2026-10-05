import Config

# The installed lmx never reads a `.env` file.
#
# req_llm loads `./.env` when its application starts, and `./` is whatever
# directory lmx was launched in: for the installed binary that is the
# repository someone just cloned. Dotenvy, which parses the file, runs `$(...)`
# command substitutions while it reads, and every variable it sets is one lmx
# honours (`LMX_CONFIG`, `LMX_BASE_URL`, `LMX_PROJECT_MCP`, `JEV_API_KEY`, a
# provider's `*_BASE_URL`). Left on, a repository's `.env` ran commands on
# `lmx --version` and could send the person's API key to an address of its
# choosing, all before any trust prompt, permission mode or sandbox existed.
# A deny-list of variable names cannot stop the command substitution, so the
# load is off entirely. Keys belong in the environment or in ~/.lmx.
#
# This is release configuration: it is baked into releases/VERSION/sys.config
# and read at VM boot, before req_llm starts. Setting it from code would run
# too late. The library itself configures nothing, so a source checkout
# (`mix lmx.tui`) still reads the checkout's own `.env`, and an embedding host
# decides for itself.
config :req_llm, load_dotenv: false

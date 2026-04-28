[oi docs] is registered and its help page renders.

  $ oi docs --help=plain 2>&1 | grep -q "Generate odoc HTML"

The man page mentions the v1 caveat about hardcoded bin paths so anyone
reading [oi docs --help] knows what they're getting.

  $ oi docs --help=plain 2>&1 | grep -q "v1:"

Outside a project (no .opam files), the command should exit with a
config-error rather than silently doing nothing.

  $ export OI_DATA_DIR=$PWD/data OI_CACHE_DIR=$PWD/cache HOME=$PWD/home
  $ mkdir -p "$HOME"
  $ cd "$(mktemp -d)"
  $ oi docs 2>&1 >/dev/null | grep -qi "no .opam files"

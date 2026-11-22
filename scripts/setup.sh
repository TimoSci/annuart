#!/usr/bin/env bash
# Prepares a new machine to run the app against a local Hardhat chain.
#
#   1. Checks the system: git, curl, a C compiler and make (the SQLite driver is compiled
#      on this machine), Node 20 or later with npm, and Elixir 1.15 or later with Erlang.
#      Nothing is installed system-wide: for whatever is missing, the script prints how
#      to install it and stops.
#   2. Installs the project's dependencies: Hardhat and the contract libraries (repo
#      root), the browser code's packages (web/assets), and the app's Elixir packages,
#      database and asset tools (mix setup). Then compiles the contracts.
#
# Safe to run again: packages are reinstalled only when they differ from the lockfile.
# Foundry is not needed for this and is not checked. Next step: scripts/local.sh
#
# Usage: scripts/setup.sh [--check]     --check: check the system, install nothing
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_NODE=20
MIN_ELIXIR="1.15"

CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    *) echo "usage: scripts/setup.sh [--check]" >&2; exit 2 ;;
  esac
done

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) OS=mac ;;
  Linux) OS=linux ;;
  *) die "unsupported system $(uname -s): this script knows macOS and Linux" ;;
esac

# --- 1. the system ----------------------------------------------------------------

PROBLEMS=0
ok() { printf '  ok       %-10s %s\n' "$1" "$2"; }
bad() { # bad <name> <what is wrong> <how to install>
  printf '  MISSING  %-10s %s\n' "$1" "$2"
  printf '           install: %s\n' "$3"
  PROBLEMS=$((PROBLEMS + 1))
}

hint() { # hint <mac command> <linux command>
  if [ "$OS" = mac ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# at_least <version> <minimum>: compares dotted numbers, e.g. 1.20.5 against 1.15
at_least() {
  local IFS=.
  # shellcheck disable=SC2206
  local have=($1) want=($2) i
  for i in 0 1 2; do
    local h=${have[$i]:-0} w=${want[$i]:-0}
    h=${h%%[!0-9]*}; w=${w%%[!0-9]*}
    if [ "${h:-0}" -gt "${w:-0}" ]; then return 0; fi
    if [ "${h:-0}" -lt "${w:-0}" ]; then return 1; fi
  done
  return 0
}

say "Checking the system"

for tool in git curl make; do
  if command -v "$tool" >/dev/null; then ok "$tool" "$(command -v "$tool")"
  else bad "$tool" "not found" "$(hint "xcode-select --install" "sudo apt-get install -y git curl build-essential")"
  fi
done

if command -v cc >/dev/null || command -v gcc >/dev/null || command -v clang >/dev/null; then
  ok "C compiler" "$(command -v cc || command -v gcc || command -v clang)"
else
  bad "C compiler" "not found (needed to build the SQLite driver)" \
    "$(hint "xcode-select --install" "sudo apt-get install -y build-essential")"
fi

NODE_HINT="$(hint "brew install node" "see https://nodejs.org/en/download (version $MIN_NODE or later)")"
if command -v node >/dev/null; then
  NODE_VERSION="$(node -p 'process.versions.node')"
  if at_least "$NODE_VERSION" "$MIN_NODE"; then ok "node" "$NODE_VERSION"
  else bad "node" "$NODE_VERSION is too old: $MIN_NODE or later is needed" "$NODE_HINT"
  fi
  if command -v npm >/dev/null; then ok "npm" "$(npm --version)"
  else bad "npm" "not found" "$NODE_HINT"
  fi
else
  bad "node" "not found" "$NODE_HINT"
fi

ELIXIR_HINT="$(hint "brew install elixir" "see https://elixir-lang.org/install.html (version $MIN_ELIXIR or later, with Erlang/OTP)")"
if command -v elixir >/dev/null && command -v mix >/dev/null && command -v erl >/dev/null; then
  ELIXIR_VERSION="$(elixir -e 'IO.puts(System.version())' 2>/dev/null || true)"
  if [ -z "$ELIXIR_VERSION" ]; then bad "elixir" "installed but does not run" "$ELIXIR_HINT"
  elif at_least "$ELIXIR_VERSION" "$MIN_ELIXIR"; then
    ok "elixir" "$ELIXIR_VERSION (Erlang/OTP $(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().'))"
  else bad "elixir" "$ELIXIR_VERSION is too old: $MIN_ELIXIR or later is needed" "$ELIXIR_HINT"
  fi
else
  bad "elixir" "elixir, mix or erl not found" "$ELIXIR_HINT"
fi

if [ "$PROBLEMS" -gt 0 ]; then
  die "$PROBLEMS thing(s) to install first; then run this script again"
fi
say "The system has everything needed"
if [ "$CHECK_ONLY" = 1 ]; then exit 0; fi

# --- 2. the project's dependencies ------------------------------------------------

# Whether node_modules holds every package the lockfile names, at the same version.
# npm keeps a record of what it installed in node_modules/.package-lock.json.
lock_satisfied() { # lock_satisfied <directory>
  [ -f "$1/node_modules/.package-lock.json" ] || return 1
  node -e '
    const fs = require("node:fs");
    const read = f => JSON.parse(fs.readFileSync(f, "utf8")).packages ?? {};
    const want = read(process.argv[1] + "/package-lock.json");
    const have = read(process.argv[1] + "/node_modules/.package-lock.json");
    for (const [name, pkg] of Object.entries(want)) {
      if (name === "" || pkg.link) continue;
      // A package for another system (optional, with os or cpu limits) may be absent.
      if (!have[name]) { if (pkg.optional) continue; process.exit(1); }
      else if (have[name].version !== pkg.version) process.exit(1);
    }
  ' "$1" 2>/dev/null
}

# Installs exactly what the lockfile names, unless that is already in place.
npm_install() { # npm_install <directory> <what>
  local dir=$1 what=$2
  if lock_satisfied "$dir"; then
    say "$what: already installed"
  else
    say "$what: installing"
    (cd "$dir" && npm ci)
  fi
}

npm_install "$ROOT" "Hardhat and contract libraries"
# Its postinstall step copies the relayer SDK into web/priv/static/vendor.
npm_install "$ROOT/web/assets" "Browser packages"

say "Contracts: compiling"
(cd "$ROOT" && npx hardhat compile)

say "App: Elixir packages, database and asset tools (mix setup)"
(
  cd "$ROOT/web"
  mix local.hex --force --if-missing
  mix local.rebar --force --if-missing
  if ! mix setup; then
    if [ "$OS" = mac ]; then
      printf 'hint: if the tailwind or esbuild binary was killed as it started, sign it and run again:\n' >&2
      printf '      (cd web && codesign -s - --force _build/tailwind-* _build/esbuild-*)\n' >&2
    fi
    exit 1
  fi
)

say "Done. Start everything with: scripts/local.sh"

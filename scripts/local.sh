#!/usr/bin/env bash
# Brings up the local development set-up and opens the app. Safe to run again at any
# time: each step is skipped when it is already done, and nothing running is restarted.
#
#   1. The local chain (Hardhat node with the FHEVM mock, port 8545): started in the
#      background unless one is already answering.
#   2. The contracts (mock, wrapped, auto, private-mock): deployed unless
#      deployments/localhost.json already names contracts that exist on this chain.
#   3. The app (Phoenix dev server, port 4000, or PORT): started in the background
#      unless it is already answering.
#   4. The app is opened in the default browser.
#
# Usage: scripts/local.sh [--no-open]
# Logs:  cache-hardhat/local/chain.log and app.log
# Stop:  kill the process ids in cache-hardhat/local/chain.pid and app.pid
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPC_URL="http://127.0.0.1:8545"
APP_URL="http://localhost:${PORT:-4000}"
DEPLOYMENTS="$ROOT/deployments/localhost.json"
RUN_DIR="$ROOT/cache-hardhat/local"
KINDS="mock wrapped auto private-mock"

OPEN=1
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN=0 ;;
    *) echo "usage: scripts/local.sh [--no-open]" >&2; exit 2 ;;
  esac
done

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v node >/dev/null || die "node is not installed"
command -v curl >/dev/null || die "curl is not installed"
mkdir -p "$RUN_DIR"

chain_id() {
  curl -s -m 5 -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$RPC_URL" 2>/dev/null |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).result||"")}catch{console.log("")}})'
}

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# Waits until the command given succeeds, or the background process dies, or time runs out.
wait_for() { # wait_for <seconds> <pid> <log> <command...>
  local seconds=$1 pid=$2 log=$3; shift 3
  local i
  for ((i = 0; i < seconds; i++)); do
    if "$@"; then return 0; fi
    if ! kill -0 "$pid" 2>/dev/null; then
      tail -n 20 "$log" >&2 || true
      die "the process stopped before it was ready; see $log"
    fi
    sleep 1
  done
  die "not ready after ${seconds}s; see $log"
}

# --- 1. the chain -----------------------------------------------------------------

chain_ready() { [ "$(chain_id)" = "0x7a69" ]; }

if chain_ready; then
  say "Local chain: already running on port 8545"
elif port_open 8545; then
  die "port 8545 is in use by something that is not a local Hardhat chain (chain id 31337)"
else
  say "Local chain: starting (log: $RUN_DIR/chain.log)"
  (cd "$ROOT" && nohup npx hardhat node >"$RUN_DIR/chain.log" 2>&1 </dev/null & echo $! >"$RUN_DIR/chain.pid")
  wait_for 180 "$(cat "$RUN_DIR/chain.pid")" "$RUN_DIR/chain.log" chain_ready
  say "Local chain: ready"
fi

# --- 2. the contracts -------------------------------------------------------------

# Prints one line per kind, "<label> ok" or "<label> missing", then "any-code yes|no":
# whether any contract the file names exists on this chain. A label is ok when the file
# names it and there is code at its address.
contract_state() {
  KINDS="$KINDS" DEPLOYMENTS="$DEPLOYMENTS" RPC_URL="$RPC_URL" node -e '
    const fs = require("node:fs");
    const hasCode = async address => {
      const res = await fetch(process.env.RPC_URL, {
        method: "POST", headers: {"content-type": "application/json"},
        body: JSON.stringify({jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [address, "latest"]}),
      });
      return (await res.json()).result !== "0x";
    };
    (async () => {
      let contracts = [];
      try { contracts = JSON.parse(fs.readFileSync(process.env.DEPLOYMENTS, "utf8")).contracts ?? []; } catch {}
      let any = false;
      const live = new Map();
      for (const c of contracts) { const ok = await hasCode(c.nft); live.set(c.label, ok); any ||= ok; }
      for (const kind of process.env.KINDS.split(" ")) console.log(kind, live.get(kind) ? "ok" : "missing");
      console.log("any-code", any ? "yes" : "no");
    })().catch(e => { console.error(e.message); process.exit(1); });
  '
}

deploy() { # deploy <label>
  local label=$1
  say "Contracts: deploying $label"
  case "$label" in
    auto) (cd "$ROOT" && REPLACE=1 NFT_KIND=auto LABEL=auto npx hardhat run scripts/deploy.ts --network localhost) ;;
    private-mock) (cd "$ROOT" && REPLACE=1 NFT_KIND=private TOKEN_KIND=mock LABEL=private-mock npx hardhat run scripts/deploy.ts --network localhost) ;;
    *) (cd "$ROOT" && REPLACE=1 TOKEN_KIND="$label" LABEL="$label" npx hardhat run scripts/deploy.ts --network localhost) ;;
  esac
}

STATE="$(contract_state)"
if ! grep -q ' missing$' <<<"$STATE"; then
  say "Contracts: already deployed ($KINDS)"
else
  if grep -q '^any-code no$' <<<"$STATE" && [ -e "$DEPLOYMENTS" ]; then
    # The file describes an earlier chain: none of its addresses exist on this one.
    say "Contracts: $DEPLOYMENTS is from an earlier chain; starting it afresh"
    rm -f "$DEPLOYMENTS"
  fi
  wrapped_redeployed=0
  for kind in $KINDS; do
    if grep -q "^$kind missing$" <<<"$STATE" || { [ "$kind" = auto ] && [ "$wrapped_redeployed" = 1 ]; }; then
      deploy "$kind"
      # auto shares the wrapped entry's token, so a new wrapped token needs a new auto.
      if [ "$kind" = wrapped ]; then wrapped_redeployed=1; fi
    fi
  done
  if grep -q ' missing$' <<<"$(contract_state)"; then die "some contracts are still missing after the deploy"; fi
  say "Contracts: deployed"
fi

# --- 3. the app -------------------------------------------------------------------

# Only this app's pages carry the annuart-chain tag; another server on the port does not count.
app_ready() { curl -s -m 5 "$APP_URL" 2>/dev/null | grep -q 'name="annuart-chain"'; }

if app_ready; then
  say "App: already running at $APP_URL"
elif port_open "${PORT:-4000}"; then
  die "port ${PORT:-4000} is in use by something that is not this app; stop it, or choose another port: PORT=4001 scripts/local.sh"
else
  [ -d "$ROOT/web/deps" ] && [ -d "$ROOT/web/assets/node_modules" ] ||
    die "the app is not set up; run once: cd web && npm install --prefix assets && mix setup"
  say "App: starting (log: $RUN_DIR/app.log)"
  (cd "$ROOT/web" && nohup mix phx.server >"$RUN_DIR/app.log" 2>&1 </dev/null & echo $! >"$RUN_DIR/app.pid")
  wait_for 300 "$(cat "$RUN_DIR/app.pid")" "$RUN_DIR/app.log" app_ready
  say "App: ready"
fi

# The app reads the deployment file once, when it starts. Warn if it serves other addresses.
if ! APP_URL="$APP_URL" DEPLOYMENTS="$DEPLOYMENTS" node -e '
  const fs = require("node:fs");
  (async () => {
    const html = await (await fetch(process.env.APP_URL)).text();
    const meta = html.match(/<meta[^>]*name="annuart-chain"[^>]*content="([^"]*)"/);
    const served = meta ? JSON.parse(meta[1].replaceAll("&quot;", "\"")).contracts ?? [] : [];
    const key = list => list.map(c => `${c.label}=${c.nft.toLowerCase()}`).sort().join(",");
    const file = JSON.parse(fs.readFileSync(process.env.DEPLOYMENTS, "utf8")).contracts;
    process.exit(key(served) === key(file) ? 0 : 1);
  })().catch(() => process.exit(1));
'; then
  printf 'warning: the running app does not serve the contracts in %s.\n' "$DEPLOYMENTS" >&2
  printf '         It reads that file only when it starts: restart the app to pick them up.\n' >&2
fi

# --- 4. the browser ---------------------------------------------------------------

if [ "$OPEN" = 1 ]; then
  if command -v open >/dev/null; then open "$APP_URL"
  elif command -v xdg-open >/dev/null; then xdg-open "$APP_URL" >/dev/null 2>&1 &
  else say "Open $APP_URL in a browser"
  fi
fi
say "Done: $APP_URL"

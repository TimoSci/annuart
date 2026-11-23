#!/usr/bin/env bash
# Shortcut: mints the fixture ENFTs on the local chain (see scripts/fixtures.ts).
# Needs the chain running and the contracts deployed; scripts/local.sh does both.
#
# Usage: scripts/fixtures.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! curl -s -m 5 -o /dev/null -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' http://127.0.0.1:8545; then
  echo "error: no local chain answers on port 8545; start it with scripts/local.sh" >&2
  exit 1
fi

cd "$ROOT"
exec npx hardhat run scripts/fixtures.ts --network localhost

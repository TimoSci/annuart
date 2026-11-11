// Two roles, both about the deployment the flows run against.
//
// Run as a script (`node e2e/global-setup.js`, from the Phoenix webServer
// command in playwright.config.js): deploys the mock and the wrapped variant to
// the Hardhat node at 8545, writing deployments/localhost.json. This runs
// before `mix phx.server`, because Phoenix reads that file when it starts and
// the indexer's first sync follows straight after.
//
// As Playwright's globalSetup (default export): checks that both variants are
// deployed and that the Phoenix server is serving them, so a broken set-up
// fails once, here, instead of in every flow.
import {execFileSync} from "node:child_process";
import {readFileSync, readdirSync, statSync} from "node:fs";
import {fileURLToPath, pathToFileURL} from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(here, "../..");
export const DEPLOYMENTS = path.join(REPO_ROOT, "deployments/localhost.json");
export const RPC_URL = "http://127.0.0.1:8545";
export const KINDS = ["mock", "wrapped"];

export function deploy() {
  for (const kind of KINDS) {
    execFileSync("npx", ["hardhat", "run", "scripts/deploy.ts", "--network", "localhost"], {
      cwd: REPO_ROOT,
      env: {...process.env, TOKEN_KIND: kind, LABEL: kind},
      stdio: "inherit",
    });
  }
}

export function readDeployments() {
  return JSON.parse(readFileSync(DEPLOYMENTS, "utf8"));
}

export async function rpc(method, params = []) {
  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({jsonrpc: "2.0", id: 1, method, params}),
  });
  const body = await res.json();
  if (body.error) throw new Error(`${method}: ${JSON.stringify(body.error)}`);
  return body.result;
}

// The dev server's esbuild and tailwind watchers rebuild the bundles once
// when they start, which can land after the server answers. A page loaded
// before that would hold stale bundles (and LiveView's static tracking then
// reloads it when it next joins). Wait until the built assets have not
// changed for a few seconds. (Live reload is off for this run; see
// playwright.config.js.)
const ASSETS = path.resolve(here, "../priv/static/assets");
const newestAsset = () => Math.max(0, ...readdirSync(ASSETS, {recursive: true})
  .map(f => statSync(path.join(ASSETS, f))).filter(s => s.isFile()).map(s => s.mtimeMs));

async function assetsSettled({quiet = 5_000, timeout = 120_000} = {}) {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    if (Date.now() - newestAsset() >= quiet) return;
    await new Promise(r => setTimeout(r, 500));
  }
  throw new Error(`the assets in ${ASSETS} kept changing for ${timeout / 1000}s`);
}

export default async function globalSetup(config) {
  await assetsSettled();
  const {contracts} = readDeployments();
  for (const kind of KINDS) {
    const c = contracts.find(x => x.label === kind);
    if (!c) throw new Error(`deployments/localhost.json has no "${kind}" contract`);
    const code = await rpc("eth_getCode", [c.nft, "latest"]);
    if (code === "0x") throw new Error(`no code at the ${kind} EndowmentNFT ${c.nft}: deploy did not reach this node`);
  }
  const baseURL = config.projects[0].use.baseURL;
  const html = await (await fetch(baseURL)).text();
  const meta = html.match(/<meta[^>]*name="annuart-chain"[^>]*content="([^"]*)"/);
  const served = meta ? JSON.parse(meta[1].replaceAll("&quot;", '"')) : null;
  for (const kind of KINDS) {
    if (!served?.contracts?.some(c => c.label === kind)) {
      throw new Error(`the Phoenix server does not serve the "${kind}" contract; was it started before the deploy?`);
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) deploy();

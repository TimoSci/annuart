// Reads what scripts/deploy.ts needs to know about a WETH contract or a token wrapping one.
// The decisions are in deployGuard.ts and preflight.ts; this file does the chain reads.
import { Contract, type Provider } from "ethers";
import { reusedUnderlying } from "./deployGuard";
import { wethProblem } from "./preflight";

// The WETH rule (preflight.ts wethProblem) applied to the contract at `address`. null when it holds.
export async function wethProblemAt(provider: Provider, address: string): Promise<string | null> {
  const hasCode = (await provider.getCode(address)) !== "0x";
  const c = new Contract(
    address,
    ["function symbol() view returns (string)", "function decimals() view returns (uint8)"],
    provider,
  );
  const symbol = hasCode ? await c.symbol().then(String, () => null) : null;
  const decimals = hasCode ? await c.decimals().then(Number, () => null) : null;
  return wethProblem({ address, hasCode, symbol, decimals });
}

// For an existing token used as a wrapped token: its underlying, if that is a WETH contract
// (and the one named by WETH_ADDRESS, which is required on a public network).
export async function reusedWrappedUnderlying(
  provider: Provider,
  i: { token: string; wethAddress: string | undefined; isLocal: boolean },
): Promise<{ underlying: string } | { refusal: string }> {
  const reported = await new Contract(i.token, ["function underlying() view returns (address)"], provider)
    .underlying()
    .then(String, () => null);
  const r = reusedUnderlying({ reported, wethAddress: i.wethAddress, isLocal: i.isLocal });
  if ("refusal" in r) return r;
  const problem = await wethProblemAt(provider, r.underlying);
  if (problem) return { refusal: `TOKEN_ADDRESS ${i.token} does not wrap WETH. ${problem}` };
  return r;
}

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";

export type Deployment = {
  label: string;
  nft: string;
  token: string;
  tokenKind: "mock" | "wrapped" | "plain";
  // Absent means the standard EndowmentNFT; "auto" is the AutoPayoutEndowmentNFT.
  nftKind?: "auto";
  underlying: string | null;
  deployBlock: number;
};

export type DeploymentFile = { chainId: number; contracts: Deployment[] };

const fileFor = (network: string) => `deployments/${network}.json`;

export function readDeployments(network: string): DeploymentFile {
  const path = fileFor(network);
  if (!existsSync(path)) return { chainId: 0, contracts: [] };
  return JSON.parse(readFileSync(path, "utf8"));
}

export function upsertDeployment(network: string, chainId: number, d: Deployment): void {
  const file = readDeployments(network);
  const i = file.contracts.findIndex((c) => c.label === d.label);
  if (i >= 0) file.contracts[i] = d;
  else file.contracts.push(d);
  mkdirSync("deployments", { recursive: true });
  writeFileSync(fileFor(network), JSON.stringify({ chainId, contracts: file.contracts }, null, 2) + "\n");
}

export function findDeployment(network: string, label?: string): Deployment | undefined {
  const { contracts } = readDeployments(network);
  return label ? contracts.find((c) => c.label === label) : contracts[0];
}

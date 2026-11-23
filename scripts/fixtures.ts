import { ethers, fhevm, network } from "hardhat";
import hre from "hardhat";
import { readDeployments } from "../tasks/deployments";
import { createFixtures } from "../tasks/fixtures";

// Mints the fixture ENFTs (tasks/fixtures.ts) on the local chain, on the contracts
// recorded in deployments/localhost.json. Local chains only. Run it again and it adds
// nothing: a fixture its creator has already minted is left alone.
//
//   npx hardhat run scripts/fixtures.ts --network localhost
//
// The creators and owners are the node's first five accounts (the ones `npx hardhat node`
// prints), so importing those keys into a wallet shows the fixtures from each side.
async function main() {
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  if (network.name !== "localhost" || chainId !== 31337) {
    throw new Error(
      `fixtures are for the local chain only: run with --network localhost (got network "${network.name}", chain id ${chainId})`,
    );
  }
  const { contracts } = readDeployments(network.name);
  if (contracts.length === 0) {
    throw new Error("deployments/localhost.json names no contracts: deploy first (scripts/local.sh does)");
  }
  for (const c of contracts) {
    if ((await ethers.provider.getCode(c.nft)) === "0x") {
      throw new Error(`no contract at the "${c.label}" address ${c.nft}: the deployment file is from another chain; redeploy`);
    }
  }
  await fhevm.initializeCLIApi();

  const results = await createFixtures(hre, contracts);
  const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
  console.log("");
  for (const r of results) {
    const id = r.tokenId === null ? "-" : `#${r.tokenId}`;
    console.log(
      `${r.status.padEnd(11)} ${(r.label ?? `(${r.variant})`).padEnd(13)} ${id.padEnd(5)} ` +
        `${(r.name || "(unnamed)").padEnd(20)} creator ${short(r.creator)}  owner ${short(r.owner)}`,
    );
  }
  const count = (s: string) => results.filter((r) => r.status === s).length;
  console.log(`\n${count("created")} created, ${count("exists")} already there, ${count("no contract")} skipped (variant not deployed)`);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exitCode = 1;
});

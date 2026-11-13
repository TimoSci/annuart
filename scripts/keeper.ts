import { ethers, fhevm, network } from "hardhat";
import { readDeployments } from "../tasks/deployments";
import { keeperRefusal, runKeeperPass, type KeeperContract, type PublicDecrypt } from "../tasks/keeper";
import { redact } from "../tasks/preflight";

// One keeper pass: finishes pending automatic payouts, requests the due ones, and finishes
// those too. Whoever runs it pays the gas and receives any fee the owners set.
//
//   KEEPER_INCLUDE_DRY  "1" to also request tokens whose last payout was zero
//   CONFIRM_KEEPER      must equal the network name on a public network (e.g. sepolia)
async function main() {
  const isLocal = network.name === "localhost" || network.name === "hardhat";
  const signers = await ethers.getSigners();
  if (signers.length === 0) {
    throw new Error(`PRIVATE_KEY is not set (network "${network.name}" has no signer)`);
  }
  const keeper = signers[0];
  const balance = await ethers.provider.getBalance(keeper.address);
  console.log(`Network: ${network.name}`);
  console.log(`Keeper:  ${keeper.address}`);
  console.log(`Balance: ${ethers.formatEther(balance)} ETH`);

  const refusal = keeperRefusal({ network: network.name, isLocal, confirm: process.env.CONFIRM_KEEPER });
  if (refusal) throw new Error(refusal);

  const autos = readDeployments(network.name).contracts.filter((c) => c.nftKind === "auto");
  if (autos.length === 0) {
    console.log(`No automatic-payout contracts in deployments/${network.name}.json; nothing to do.`);
    return;
  }
  const contracts = await Promise.all(
    autos.map(async (d) => ({
      label: d.label,
      contract: (await ethers.getContractAt("AutoPayoutEndowmentNFT", d.nft, keeper)) as unknown as KeeperContract,
    })),
  );

  const result = await runKeeperPass({
    contracts,
    publicDecrypt: (handles) => fhevm.publicDecrypt(handles as `0x${string}`[]) as unknown as ReturnType<PublicDecrypt>,
    includeDry: process.env.KEEPER_INCLUDE_DRY === "1",
    log: (line) => console.log(line),
    secrets: [process.env.SEPOLIA_RPC_URL],
  });
  console.log(`Done: ${result.requested} requested, ${result.finished} finished, ${result.failed} failed.`);
  if (result.failed > 0) process.exitCode = 1;
}

main().catch((e) => {
  console.error(redact(e instanceof Error ? e.message : String(e), [process.env.SEPOLIA_RPC_URL]));
  process.exitCode = 1;
});

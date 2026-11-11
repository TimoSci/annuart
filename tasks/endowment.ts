import { task } from "hardhat/config";
import { FhevmType } from "@fhevm/hardhat-plugin";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { findDeployment } from "./deployments";

const U64_MAX = (1n << 64n) - 1n;

// The deployment for the active network (by --label, else the first entry); --nft/--token override it.
function loadDeployment(hre: HardhatRuntimeEnvironment, label?: string) {
  const d = findDeployment(hre.network.name, label);
  return {
    nft: d?.nft ?? "",
    token: d?.token ?? "",
    tokenKind: d?.tokenKind,
  };
}

const LABEL_DESC = "Deployment label in deployments/<network>.json (defaults to the first entry)";

task("task:mint", "Mint an endowment NFT funded with a secret endowment")
  .addParam("amount", "Endowment amount in base units")
  .addOptionalParam("topups", "Allow top-ups: true/false", "false")
  .addOptionalParam("name", "Public name, up to 31 characters: letters, digits, space and - _ . '", "")
  .addOptionalParam("label", LABEL_DESC)
  .addOptionalParam("nft", "EndowmentNFT address (defaults to the deployment file)")
  .addOptionalParam("token", "Confidential token address (defaults to the deployment file)")
  .setAction(async (args, hre) => {
    const { ethers, fhevm } = hre;
    await fhevm.initializeCLIApi();
    const dep = loadDeployment(hre, args.label);
    const nftAddr: string = args.nft || dep.nft;
    const tokenAddr: string = args.token || dep.token;
    if (!args.token && dep.tokenKind !== "mock") {
      throw new Error(
        `task:mint only mints test tokens for a mock token; this deployment's token is "${dep.tokenKind}" (not a mock token). Fund your account with the token yourself, or pass --label for a mock deployment.`,
      );
    }
    const [signer] = await ethers.getSigners();
    const amount = BigInt(args.amount);
    const topups = String(args.topups) === "true";
    const name = args.name ? ethers.encodeBytes32String(String(args.name)) : ethers.ZeroHash;

    const token = await ethers.getContractAt("MockConfidentialToken", tokenAddr, signer);
    await (await token.mint(signer.address, amount)).wait();
    const until = Math.floor(Date.now() / 1000) + 365 * 24 * 3600;
    await (await token.setOperator(nftAddr, until)).wait();

    const enc = await fhevm
      .createEncryptedInput(nftAddr, signer.address)
      .add64(amount)
      .encrypt();

    const nft = await ethers.getContractAt("EndowmentNFT", nftAddr, signer);
    const segments = [{ duration: 3600, ratePerSec: 1 }]; // 1 unit/sec for 1 hour
    const receipt = await (
      await nft.mint(signer.address, enc.handles[0], enc.inputProof, segments, 0, topups, name)
    ).wait();

    let tokenId = "?";
    for (const log of receipt!.logs) {
      try {
        const parsed = nft.interface.parseLog(log);
        if (parsed?.name === "Transfer") tokenId = parsed.args.tokenId.toString();
      } catch {
        /* not an EndowmentNFT event */
      }
    }
    console.log(`Minted EndowmentNFT tokenId=${tokenId} (amount=${amount}, topUps=${topups})`);
  });

task("task:accrue", "Advance a token's distribution accrual (anyone may call)")
  .addParam("id", "tokenId")
  .addOptionalParam("label", LABEL_DESC)
  .addOptionalParam("nft", "EndowmentNFT address")
  .setAction(async (args, hre) => {
    const { ethers } = hre;
    const dep = loadDeployment(hre, args.label);
    const nft = await ethers.getContractAt("EndowmentNFT", args.nft || dep.nft);
    await (await nft.accrue(BigInt(args.id))).wait();
    console.log(`Accrued tokenId=${args.id}`);
  });

task("task:claim", "Claim the accrued distribution (owner only)")
  .addParam("id", "tokenId")
  .addOptionalParam("label", LABEL_DESC)
  .addOptionalParam("nft", "EndowmentNFT address")
  .setAction(async (args, hre) => {
    const { ethers } = hre;
    const [signer] = await ethers.getSigners();
    const dep = loadDeployment(hre, args.label);
    const nft = await ethers.getContractAt("EndowmentNFT", args.nft || dep.nft, signer);
    await (await nft.claim(BigInt(args.id))).wait();
    console.log(`Claimed tokenId=${args.id} to ${signer.address}`);
  });

task("task:distribution", "Decrypt and print the distribution balance (owner only)")
  .addParam("id", "tokenId")
  .addOptionalParam("label", LABEL_DESC)
  .addOptionalParam("nft", "EndowmentNFT address")
  .setAction(async (args, hre) => {
    const { ethers, fhevm } = hre;
    await fhevm.initializeCLIApi();
    const [signer] = await ethers.getSigners();
    const dep = loadDeployment(hre, args.label);
    const nftAddr: string = args.nft || dep.nft;
    const nft = await ethers.getContractAt("EndowmentNFT", nftAddr, signer);
    const handle = await nft.distributionHandle(BigInt(args.id));
    const clear = await fhevm.userDecryptEuint(FhevmType.euint64, handle, nftAddr, signer);
    console.log(`distribution(tokenId=${args.id}) = ${clear}`);
  });

task("task:info", "Print public info for a token")
  .addParam("id", "tokenId")
  .addOptionalParam("label", LABEL_DESC)
  .addOptionalParam("nft", "EndowmentNFT address")
  .setAction(async (args, hre) => {
    const { ethers } = hre;
    const dep = loadDeployment(hre, args.label);
    const nft = await ethers.getContractAt("EndowmentNFT", args.nft || dep.nft);
    const id = BigInt(args.id);
    console.log(`owner      = ${await nft.ownerOf(id)}`);
    console.log(`topUps     = ${await nft.topUpsAllowedOf(id)}`);
    const name = ethers.decodeBytes32String(await nft.nameOf(id));
    console.log(`name       = ${name === "" ? "(none)" : name}`);
    const schedule = await nft.scheduleOf(id);
    console.log("schedule   =");
    schedule.forEach((seg: { duration: bigint; ratePerSec: bigint }, i: number) => {
      const dur = seg.duration === U64_MAX ? "indefinite" : `${seg.duration}s`;
      console.log(`  [${i}] duration=${dur} ratePerSec=${seg.ratePerSec}`);
    });
    console.log(`start      = ${await nft.scheduleStartOf(id)}`);
    const end = await nft.scheduleEndOf(id);
    console.log(`end        = ${end === U64_MAX ? "indefinite" : end}`);
    console.log(`lastAccrue = ${await nft.lastAccrualAtOf(id)}`);
    console.log(`settled    = ${await nft.settledOf(id)}`);
    console.log(`distHandle = ${await nft.distributionHandle(id)}`);
    console.log("(endowment balance is intentionally not decryptable by the owner)");
  });

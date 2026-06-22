import { task } from "hardhat/config";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { readFileSync } from "fs";

function loadDeployment(): { token: string; nft: string } {
  try {
    return JSON.parse(readFileSync("deployments/local.json", "utf8"));
  } catch {
    return { token: "", nft: "" };
  }
}

task("task:mint", "Mint an endowment NFT funded with a secret endowment")
  .addParam("amount", "Endowment amount in base units")
  .addOptionalParam("topups", "Allow top-ups: true/false", "false")
  .addOptionalParam("nft", "EndowmentNFT address (defaults to deployments/local.json)")
  .addOptionalParam("token", "Confidential token address (defaults to deployments/local.json)")
  .setAction(async (args, hre) => {
    const { ethers, fhevm } = hre;
    await fhevm.initializeCLIApi();
    const dep = loadDeployment();
    const nftAddr: string = args.nft || dep.nft;
    const tokenAddr: string = args.token || dep.token;
    const [signer] = await ethers.getSigners();
    const amount = BigInt(args.amount);
    const topups = String(args.topups) === "true";

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
      await nft.mint(signer.address, enc.handles[0], enc.inputProof, segments, 0, topups)
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
  .addOptionalParam("nft", "EndowmentNFT address")
  .setAction(async (args, hre) => {
    const { ethers } = hre;
    const dep = loadDeployment();
    const nft = await ethers.getContractAt("EndowmentNFT", args.nft || dep.nft);
    await (await nft.accrue(BigInt(args.id))).wait();
    console.log(`Accrued tokenId=${args.id}`);
  });

task("task:claim", "Claim the accrued distribution (owner only)")
  .addParam("id", "tokenId")
  .addOptionalParam("nft", "EndowmentNFT address")
  .setAction(async (args, hre) => {
    const { ethers } = hre;
    const [signer] = await ethers.getSigners();
    const dep = loadDeployment();
    const nft = await ethers.getContractAt("EndowmentNFT", args.nft || dep.nft, signer);
    await (await nft.claim(BigInt(args.id))).wait();
    console.log(`Claimed tokenId=${args.id} to ${signer.address}`);
  });

task("task:distribution", "Decrypt and print the distribution balance (owner only)")
  .addParam("id", "tokenId")
  .addOptionalParam("nft", "EndowmentNFT address")
  .setAction(async (args, hre) => {
    const { ethers, fhevm } = hre;
    await fhevm.initializeCLIApi();
    const [signer] = await ethers.getSigners();
    const dep = loadDeployment();
    const nftAddr: string = args.nft || dep.nft;
    const nft = await ethers.getContractAt("EndowmentNFT", nftAddr, signer);
    const handle = await nft.distributionHandle(BigInt(args.id));
    const clear = await fhevm.userDecryptEuint(FhevmType.euint64, handle, nftAddr, signer);
    console.log(`distribution(tokenId=${args.id}) = ${clear}`);
  });

task("task:info", "Print public info for a token")
  .addParam("id", "tokenId")
  .addOptionalParam("nft", "EndowmentNFT address")
  .setAction(async (args, hre) => {
    const { ethers } = hre;
    const dep = loadDeployment();
    const nft = await ethers.getContractAt("EndowmentNFT", args.nft || dep.nft);
    const id = BigInt(args.id);
    console.log(`owner      = ${await nft.ownerOf(id)}`);
    console.log(`topUps     = ${await nft.topUpsAllowedOf(id)}`);
    console.log(`distHandle = ${await nft.distributionHandle(id)}`);
    console.log("(endowment balance is intentionally not decryptable by the owner)");
  });

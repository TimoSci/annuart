import { ethers } from "hardhat";
import { mkdirSync, writeFileSync } from "fs";

// Deploys the confidential token (a dev mock, unless TOKEN_ADDRESS is set to a real
// ERC7984) and the EndowmentNFT, then records the addresses in deployments/local.json
// so the task:* commands can find them.
async function main() {
  let tokenAddr = process.env.TOKEN_ADDRESS;
  if (!tokenAddr) {
    const Token = await ethers.getContractFactory("MockConfidentialToken");
    const token = await Token.deploy();
    await token.waitForDeployment();
    tokenAddr = await token.getAddress();
    console.log("MockConfidentialToken:", tokenAddr);
  } else {
    console.log("Using existing token:", tokenAddr);
  }

  const NFT = await ethers.getContractFactory("EndowmentNFT");
  const nft = await NFT.deploy(tokenAddr);
  await nft.waitForDeployment();
  const nftAddr = await nft.getAddress();
  console.log("EndowmentNFT:", nftAddr);

  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  mkdirSync("deployments", { recursive: true });
  writeFileSync(
    "deployments/local.json",
    JSON.stringify({ token: tokenAddr, nft: nftAddr, chainId }, null, 2) + "\n",
  );
  console.log("Wrote deployments/local.json");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

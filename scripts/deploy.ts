import { ethers, network } from "hardhat";
import { upsertDeployment, type Deployment } from "../tasks/deployments";

// Deploys an EndowmentNFT with a confidential token and records it in
// deployments/<network>.json so the task:* commands (and the web app) can find it.
//
//   TOKEN_KIND     mock (default) | wrapped | plain
//   LABEL          name of the entry in the deployment file (default: the token kind)
//   WETH_ADDRESS   wrapped: the WETH to wrap (a MockWETH is deployed on localhost/hardhat if unset)
//   TOKEN_ADDRESS  plain: an existing ERC7984 token
async function main() {
  const kind = (process.env.TOKEN_KIND || "mock") as Deployment["tokenKind"];
  if (!["mock", "wrapped", "plain"].includes(kind)) {
    throw new Error(`TOKEN_KIND must be mock, wrapped or plain (got "${kind}")`);
  }
  const label = process.env.LABEL || kind;
  const isLocal = network.name === "localhost" || network.name === "hardhat";

  let tokenAddr: string;
  let underlying: string | null = null;
  if (kind === "mock") {
    const token = await (await ethers.getContractFactory("MockConfidentialToken")).deploy();
    await token.waitForDeployment();
    tokenAddr = await token.getAddress();
    console.log("MockConfidentialToken:", tokenAddr);
  } else if (kind === "wrapped") {
    underlying = process.env.WETH_ADDRESS || null;
    if (!underlying) {
      if (!isLocal) throw new Error("WETH_ADDRESS is required for TOKEN_KIND=wrapped on this network");
      const weth = await (await ethers.getContractFactory("MockWETH")).deploy();
      await weth.waitForDeployment();
      underlying = await weth.getAddress();
      console.log("MockWETH:", underlying);
    }
    const token = await (await ethers.getContractFactory("ConfidentialWETH")).deploy(underlying);
    await token.waitForDeployment();
    tokenAddr = await token.getAddress();
    console.log("ConfidentialWETH:", tokenAddr);
  } else {
    if (!process.env.TOKEN_ADDRESS) throw new Error("TOKEN_ADDRESS is required for TOKEN_KIND=plain");
    tokenAddr = process.env.TOKEN_ADDRESS;
    console.log("Using existing token:", tokenAddr);
  }

  const nft = await (await ethers.getContractFactory("EndowmentNFT")).deploy(tokenAddr);
  const receipt = await nft.deploymentTransaction()!.wait();
  const nftAddr = await nft.getAddress();
  console.log("EndowmentNFT:", nftAddr);

  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  upsertDeployment(network.name, chainId, {
    label,
    nft: nftAddr,
    token: tokenAddr,
    tokenKind: kind,
    underlying,
    deployBlock: receipt!.blockNumber,
  });
  console.log(`Wrote deployments/${network.name}.json (label "${label}")`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

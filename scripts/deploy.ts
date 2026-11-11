import { ethers, network } from "hardhat";
import { readDeployments, upsertDeployment, type Deployment } from "../tasks/deployments";
import { deployRefusal, reusedUnderlying } from "../tasks/deployGuard";

// Deploys an EndowmentNFT with a confidential token and records it in
// deployments/<network>.json so the task:* commands (and the web app) can find it.
//
//   TOKEN_KIND     mock (default) | wrapped | plain
//   LABEL          name of the entry in the deployment file (default: the token kind)
//   WETH_ADDRESS   wrapped: the WETH to wrap (a MockWETH is deployed on localhost/hardhat if unset)
//   TOKEN_ADDRESS  plain: an existing ERC7984 token; mock/wrapped: reuse this token instead of deploying one
//   CONFIRM_DEPLOY must equal the network name on a public network (e.g. sepolia)
//   REPLACE        "1" to overwrite a label already recorded for this network
async function main() {
  const kind = (process.env.TOKEN_KIND || "mock") as Deployment["tokenKind"];
  if (!["mock", "wrapped", "plain"].includes(kind)) {
    throw new Error(`TOKEN_KIND must be mock, wrapped or plain (got "${kind}")`);
  }
  const label = process.env.LABEL || kind;
  const isLocal = network.name === "localhost" || network.name === "hardhat";

  const signers = await ethers.getSigners();
  if (signers.length === 0) {
    throw new Error(`PRIVATE_KEY is not set (network "${network.name}" has no signer)`);
  }
  const deployer = signers[0];
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Network:  ${network.name}`);
  console.log(`Chain id: ${chainId}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Balance:  ${ethers.formatEther(balance)} ETH`);

  const refusal = deployRefusal({
    network: network.name,
    isLocal,
    chainId,
    expectedChainId: network.config.chainId,
    confirm: process.env.CONFIRM_DEPLOY,
    label,
    existingLabels: readDeployments(network.name).contracts.map((c) => c.label),
    replace: process.env.REPLACE === "1",
  });
  if (refusal) throw new Error(refusal);

  // mock and wrapped may reuse an already deployed token instead of deploying one.
  const reuse = process.env.TOKEN_ADDRESS;
  if (reuse && (await ethers.provider.getCode(reuse)) === "0x") {
    throw new Error(`TOKEN_ADDRESS ${reuse} has no contract code on ${network.name}`);
  }

  let tokenAddr: string;
  let underlying: string | null = null;
  if (reuse) {
    tokenAddr = reuse;
    if (kind === "wrapped") {
      const reported = await new ethers.Contract(reuse, ["function underlying() view returns (address)"], ethers.provider)
        .underlying()
        .then(String, () => null);
      const r = reusedUnderlying({ reported, wethAddress: process.env.WETH_ADDRESS });
      if ("refusal" in r) throw new Error(r.refusal);
      underlying = r.underlying;
    }
    console.log("Using existing token:", tokenAddr);
  } else if (kind === "mock") {
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
  console.error(e instanceof Error ? e.message : e);
  process.exitCode = 1;
});

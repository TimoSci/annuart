import { ethers, network } from "hardhat";
import { readDeployments, upsertDeployment, type Deployment } from "../tasks/deployments";
import { deployRefusal, reusedUnderlying, sentLine } from "../tasks/deployGuard";
import { redact, wethProblem } from "../tasks/preflight";

// Deploys an EndowmentNFT with a confidential token and records it in
// deployments/<network>.json so the task:* commands (and the web app) can find it.
//
//   TOKEN_KIND     mock (default) | wrapped | plain
//   LABEL          name of the entry in the deployment file (default: the token kind)
//   WETH_ADDRESS   wrapped: the WETH to wrap, checked to be one (a MockWETH is deployed on localhost/hardhat if unset)
//   TOKEN_ADDRESS  plain: an existing ERC7984 token; mock/wrapped: reuse this token instead of deploying one
//   CONFIRM_DEPLOY must equal the network name on a public network (e.g. sepolia)
//   REPLACE        "1" to overwrite a label already recorded for this network
// Deploys `name`, printing its address and transaction hash as soon as the transaction
// is sent, then waits for it to be mined and prints the `<name>: <address>` line.
async function deployContract(name: string, ...args: unknown[]) {
  const contract = await (await ethers.getContractFactory(name)).deploy(...args);
  const address = await contract.getAddress();
  console.log(sentLine(name, address, contract.deploymentTransaction()!.hash));
  const receipt = await contract.deploymentTransaction()!.wait();
  console.log(`${name}:`, address);
  return { address, receipt: receipt! };
}

// Refuses a WETH_ADDRESS that is not a WETH contract (the pre-flight's rule).
async function checkWeth(address: string) {
  const hasCode = (await ethers.provider.getCode(address)) !== "0x";
  const c = new ethers.Contract(
    address,
    ["function symbol() view returns (string)", "function decimals() view returns (uint8)"],
    ethers.provider,
  );
  const symbol = hasCode ? await c.symbol().then(String, () => null) : null;
  const decimals = hasCode ? await c.decimals().then(Number, () => null) : null;
  const problem = wethProblem({ address, hasCode, symbol, decimals });
  if (problem) throw new Error(problem);
}

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
    tokenAddr = (await deployContract("MockConfidentialToken")).address;
  } else if (kind === "wrapped") {
    underlying = process.env.WETH_ADDRESS || null;
    if (underlying) {
      await checkWeth(underlying);
    } else {
      if (!isLocal) throw new Error("WETH_ADDRESS is required for TOKEN_KIND=wrapped on this network");
      underlying = (await deployContract("MockWETH")).address;
    }
    tokenAddr = (await deployContract("ConfidentialWETH", underlying)).address;
  } else {
    if (!process.env.TOKEN_ADDRESS) throw new Error("TOKEN_ADDRESS is required for TOKEN_KIND=plain");
    tokenAddr = process.env.TOKEN_ADDRESS;
    console.log("Using existing token:", tokenAddr);
  }

  const { address: nftAddr, receipt } = await deployContract("EndowmentNFT", tokenAddr);

  upsertDeployment(network.name, chainId, {
    label,
    nft: nftAddr,
    token: tokenAddr,
    tokenKind: kind,
    underlying,
    deployBlock: receipt.blockNumber,
  });
  console.log(`Wrote deployments/${network.name}.json (label "${label}")`);
}

main().catch((e) => {
  // ethers copies the keyed RPC URL into HTTP errors.
  console.error(redact(e instanceof Error ? e.message : String(e), [process.env.SEPOLIA_RPC_URL]));
  process.exitCode = 1;
});

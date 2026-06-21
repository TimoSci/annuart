import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/node";
import { JsonRpcProvider, Wallet } from "ethers";

export async function setup() {
  const provider = new JsonRpcProvider(process.env.SEPOLIA_RPC_URL!);
  const wallet = new Wallet(process.env.PRIVATE_KEY!, provider);
  // SepoliaConfig is exported from @zama-fhe/relayer-sdk@0.4.4 as
  // `Omit<FhevmInstanceConfig, 'network'>`. We supply the `network` field
  // (an Eip1193Provider or RPC URL string) to complete the config.
  const instance = await createInstance({
    ...SepoliaConfig,
    network: process.env.SEPOLIA_RPC_URL!,
  });
  return { provider, wallet, instance };
}

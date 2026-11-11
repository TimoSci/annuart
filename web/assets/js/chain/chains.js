// What the app knows about chains besides the one it is deployed to.
export const DEV_CHAIN = 31337;

const CHAINS = {
  11155111: {
    chainId: "0xaa36a7",
    chainName: "Sepolia",
    nativeCurrency: {name: "Sepolia Ether", symbol: "ETH", decimals: 18},
    rpcUrls: ["https://ethereum-sepolia-rpc.publicnode.com"],
    blockExplorerUrls: ["https://sepolia.etherscan.io"],
  },
};

// The wallet_addEthereumChain parameter for `chainId`, or null when unknown.
export function addChainParams(chainId) {
  return CHAINS[chainId] ?? null;
}

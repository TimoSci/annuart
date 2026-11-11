// Browser wallet (MetaMask-style, EIP-1193). The wallet holds the keys; this
// module only asks it for accounts and hands ethers a signer that asks it to sign.
import {BrowserProvider, getAddress} from "ethers";
import {addChainParams} from "../chains.js";

const hex = n => "0x" + Number(n).toString(16);

// Wallets report "unknown chain" (4902) at the top level or nested inside the
// error they wrap it in.
const unknownChain = err =>
  err?.code === 4902 || err?.data?.originalError?.code === 4902 || err?.error?.code === 4902;

export function createWalletSigner(ethereum = window.ethereum) {
  if (!ethereum) throw new Error("No wallet found");
  const listeners = new Set();
  let listening = false;

  async function chainId() {
    return Number(BigInt(await ethereum.request({method: "eth_chainId"})));
  }

  async function sessionFor(accounts) {
    if (!accounts?.length) return null;
    // "any": the wallet may change chain under us; ethers must not throw on that.
    const provider = new BrowserProvider(ethereum, "any");
    const signer = await provider.getSigner(accounts[0]);
    return {kind: "wallet", address: getAddress(accounts[0]), signer, provider, ethereum, chainId: await chainId()};
  }

  const emit = session => listeners.forEach(fn => fn(session));

  const onAccounts = async accounts => emit(await sessionFor(accounts));
  const onChain = async () => emit(await sessionFor(await ethereum.request({method: "eth_accounts"})));

  function listen() {
    if (listening) return;
    listening = true;
    ethereum.on("accountsChanged", onAccounts);
    ethereum.on("chainChanged", onChain);
  }

  return {
    // silent: use accounts the site is already allowed to see; never prompt.
    async connect({silent = false} = {}) {
      const accounts = await ethereum.request({method: silent ? "eth_accounts" : "eth_requestAccounts"});
      const session = await sessionFor(accounts);
      if (session) listen();
      return session;
    },

    onChange(fn) {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },

    // A wallet that does not know the chain (code 4902) is asked to add it,
    // then to switch again. A chain the app has no parameters for is not added.
    async switchChain(id) {
      const switchTo = () => ethereum.request({method: "wallet_switchEthereumChain", params: [{chainId: hex(id)}]});
      try {
        await switchTo();
      } catch (err) {
        const params = addChainParams(id);
        if (!unknownChain(err) || !params) throw err;
        await ethereum.request({method: "wallet_addEthereumChain", params: [params]});
        await switchTo();
      }
    },

    close() {
      listeners.clear();
      if (!listening) return;
      listening = false;
      ethereum.removeListener?.("accountsChanged", onAccounts);
      ethereum.removeListener?.("chainChanged", onChain);
    },
  };
}

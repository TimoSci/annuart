import { Contract } from "ethers";
import { setup } from "./instance.js";

const ABI = [
  "function mint(address to, bytes32 encEndowment, bytes inputProof, (uint64 duration, uint64 ratePerSec)[] segments, uint64 scheduleStart, bool topUpsAllowed) returns (uint256)"
];
const TOKEN_ABI = ["function setOperator(address operator, uint48 until)"];

async function main() {
  const { wallet, instance } = await setup();
  const nft = process.env.NFT_ADDRESS!;
  const amount = 1_000_000n; // base units of endowment

  // 1) approve the NFT as operator on the confidential token
  const token = new Contract(process.env.TOKEN_ADDRESS!, TOKEN_ABI, wallet);
  const until = Math.floor(Date.now() / 1000) + 365 * 24 * 3600;
  await (await token.setOperator(nft, until)).wait();

  // 2) build the encrypted endowment input bound to (nft, funder)
  const enc = await instance
    .createEncryptedInput(nft, wallet.address)
    .add64(amount)
    .encrypt();

  // 3) mint: 1 unit/sec for 1 hour
  const segments = [{ duration: 3600n, ratePerSec: 1n }];
  const c = new Contract(nft, ABI, wallet);
  const tx = await c.mint(
    wallet.address, enc.handles[0], enc.inputProof, segments, 0n, true
  );
  console.log("mint tx:", (await tx.wait())?.hash);
}
main();

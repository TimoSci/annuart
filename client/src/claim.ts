import { Contract } from "ethers";
import { setup } from "./instance.js";
const ABI = ["function claim(uint256 tokenId)"];
async function main() {
  const { wallet } = await setup();
  const c = new Contract(process.env.NFT_ADDRESS!, ABI, wallet);
  console.log("claim:", (await (await c.claim(BigInt(process.env.TOKEN_ID!))).wait())?.hash);
}
main();

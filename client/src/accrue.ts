import { Contract } from "ethers";
import { setup } from "./instance.js";
const ABI = ["function accrue(uint256 tokenId)"];
async function main() {
  const { wallet } = await setup();
  const c = new Contract(process.env.NFT_ADDRESS!, ABI, wallet);
  console.log("accrue:", (await (await c.accrue(BigInt(process.env.TOKEN_ID!))).wait())?.hash);
}
main();

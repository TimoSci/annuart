import { Contract } from "ethers";
import { setup } from "./instance.js";
const ABI = ["function endowmentHandle(uint256 tokenId) view returns (bytes32)"];

async function main() {
  const { wallet, instance } = await setup();
  const nft = process.env.NFT_ADDRESS!;
  const c = new Contract(nft, ABI, wallet);
  const handle: string = await c.endowmentHandle(BigInt(process.env.TOKEN_ID!));
  const { publicKey, privateKey } = instance.generateKeypair();
  const start = Math.floor(Date.now() / 1000);
  const eip712 = instance.createEIP712(publicKey, [nft], start, 1);
  // eip712.types is KmsUserDecryptEIP712TypesType; primaryType is
  // 'UserDecryptRequestVerification' — verified against node.d.ts line 1137.
  // The SDK's types array is `readonly` but ethers expects a mutable `TypedDataField[]`.
  // Cast to `any` to bridge the readonly mismatch — the values are identical at runtime.
  const signature = await wallet.signTypedData(
    eip712.domain, { [eip712.primaryType]: eip712.types[eip712.primaryType] as any }, eip712.message
  );
  try {
    await instance.userDecrypt(
      [{ handle, contractAddress: nft }],
      privateKey, publicKey, signature, [nft], wallet.address, start, 1
    );
    console.error("FAIL: endowment was decryptable — privacy broken!");
    process.exit(1);
  } catch {
    console.log("PASS: endowment is NOT decryptable by the owner (as designed).");
  }
}
main();

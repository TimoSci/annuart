import { Contract } from "ethers";
import { setup } from "./instance.js";
const ABI = ["function distributionHandle(uint256 tokenId) view returns (bytes32)"];

async function main() {
  const { wallet, instance } = await setup();
  const nft = process.env.NFT_ADDRESS!;
  const c = new Contract(nft, ABI, wallet);
  const handle: string = await c.distributionHandle(BigInt(process.env.TOKEN_ID!));

  const { publicKey, privateKey } = instance.generateKeypair();
  const start = Math.floor(Date.now() / 1000);
  const days = 1;
  const eip712 = instance.createEIP712(publicKey, [nft], start, days);
  // eip712.types is KmsUserDecryptEIP712TypesType; primaryType is
  // 'UserDecryptRequestVerification' — verified against node.d.ts line 1137.
  // The SDK's types array is `readonly` but ethers expects a mutable `TypedDataField[]`.
  // Cast to `any` to bridge the readonly mismatch — the values are identical at runtime.
  const signature = await wallet.signTypedData(
    eip712.domain, { [eip712.primaryType]: eip712.types[eip712.primaryType] as any }, eip712.message
  );
  // userDecrypt signature (verified against FhevmInstance in node.d.ts line 720):
  //   (handles, privateKey, publicKey, signature, contractAddresses,
  //    userAddress, startTimestamp, durationDays) => Promise<UserDecryptResults>
  // UserDecryptResults = ClearValues = Record<`0x${string}`, bigint|boolean|string>
  const res = await instance.userDecrypt(
    [{ handle, contractAddress: nft }],
    privateKey, publicKey, signature, [nft], wallet.address, start, days
  );
  console.log("distribution =", res[handle as `0x${string}`]);
}
main();

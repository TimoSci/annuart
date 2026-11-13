import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

// Smoke test of the automatic payout on the in-process FHEVM mock:
// deploy -> wrap -> mintAuto -> requestPayout -> public decrypt -> finalizePayout.
// It also pins the shape of the plugin's publicDecrypt result for the keeper and web code.
describe("AutoPayoutEndowmentNFT (Hardhat + fhevm mock)", function () {
  it("request -> public decrypt -> finalise pays ETH", async function () {
    const [creator, owner, keeper] = await ethers.getSigners();

    const weth = await (await ethers.getContractFactory("MockWETH")).deploy();
    await weth.waitForDeployment();
    const cweth = await (await ethers.getContractFactory("ConfidentialWETH")).deploy(await weth.getAddress());
    await cweth.waitForDeployment();
    const cwethAddr = await cweth.getAddress();
    const nft = await (await ethers.getContractFactory("AutoPayoutEndowmentNFT")).deploy(cwethAddr);
    await nft.waitForDeployment();
    const nftAddr = await nft.getAddress();

    // 1000 cWETH units (1e9 wei each), wrapped by the creator, with the NFT as operator.
    const units = 1000n;
    const rate = await cweth.rate();
    expect(rate).to.equal(10n ** 9n);
    await (await weth.deposit({ value: units * rate })).wait();
    await (await weth.approve(cwethAddr, units * rate)).wait();
    await (await cweth.wrap(creator.address, units * rate)).wait();
    await (await cweth.setOperator(nftAddr, (await time.latest()) + 365 * 24 * 3600)).wait();

    const enc = await fhevm.createEncryptedInput(nftAddr, creator.address).add64(Number(units)).encrypt();
    const segments = [{ duration: 1000, ratePerSec: 1 }]; // 1 unit/s for 1000 s
    const mintRcpt = await (
      await nft.mintAuto(
        owner.address,
        enc.handles[0],
        enc.inputProof,
        segments,
        0,
        false,
        ethers.ZeroHash,
        true,
        3600,
        0,
      )
    ).wait();
    const scheduleStart = BigInt((await ethers.provider.getBlock(mintRcpt!.blockNumber))!.timestamp);
    const tokenId = 1n;
    expect(await nft.payoutDue(tokenId)).to.equal(true);

    await time.increase(100);

    // Anyone may request; the request id is in PayoutRequested and in pendingPayoutOf.
    const reqRcpt = await (await nft.connect(keeper).requestPayout(tokenId, 0)).wait();
    const requestTs = BigInt((await ethers.provider.getBlock(reqRcpt!.blockNumber))!.timestamp);
    const requested = reqRcpt!.logs
      .map((l: { topics: ReadonlyArray<string>; data: string }) => {
        try {
          return nft.interface.parseLog(l);
        } catch {
          return null;
        }
      })
      .find((e: { name: string } | null) => e?.name === "PayoutRequested");
    expect(requested, "PayoutRequested event").to.not.equal(undefined);
    const requestId: string = requested!.args.requestId;
    expect(requested!.args.recipient).to.equal(owner.address);
    expect(requested!.args.requester).to.equal(keeper.address);
    const pending = await nft.pendingPayoutOf(tokenId);
    expect(pending.requestId).to.equal(requestId);

    // The plugin returns { clearValues: { [handle]: bigint }, abiEncodedClearValues, decryptionProof }.
    const decrypted = await fhevm.publicDecrypt([requestId]);
    const clear = BigInt(decrypted.clearValues[requestId as `0x${string}`] as bigint);
    expect(clear).to.equal(requestTs - scheduleStart);

    const ownerBefore = await ethers.provider.getBalance(owner.address);
    await (await nft.connect(keeper).finalizePayout(tokenId, clear, decrypted.decryptionProof)).wait();
    const ownerAfter = await ethers.provider.getBalance(owner.address);

    expect(ownerAfter - ownerBefore).to.equal(clear * rate);
    expect((await nft.pendingPayoutOf(tokenId)).requestId).to.equal(ethers.ZeroHash);
    const last = await nft.lastPayoutOf(tokenId);
    expect(last.amountWei).to.equal(clear * rate);
    expect(await weth.balanceOf(nftAddr)).to.equal(0n);
  });
});

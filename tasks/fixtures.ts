import type { HardhatRuntimeEnvironment } from "hardhat/types";

// Fixture ENFTs for a local chain: a fixed set covering every contract variant, several
// creators and owners, the mint options, the shapes a schedule can take, and endowments
// from one base unit to more than the schedule needs. scripts/fixtures.ts runs it against
// the deployments of a local node; test/fixtures.hh.ts runs it in process.

export type FixtureContract = {
  label: string;
  nft: string;
  token: string;
  tokenKind: "mock" | "wrapped" | "plain";
  nftKind?: "auto" | "private";
};

type Variant = "mock" | "wrapped" | "auto" | "private";

// Durations in seconds; rates in token base units per second, or weights (1000 = 100%)
// on the private-rate variant.
type Seg = { duration: bigint; ratePerSec: bigint };

export type Fixture = {
  variant: Variant;
  /** Public name; "" leaves the token unnamed. A fixture is identified by creator and name. */
  name: string;
  /** Indexes into the node's accounts. */
  creator: number;
  owner: number;
  /** Endowment in token base units. */
  amount: bigint;
  segments: Seg[];
  /** Seconds from now to the schedule's start: 0 starts at the mint, negative is in the past. */
  startOffset: number;
  topUps: boolean;
  /** Automatic payout settings (auto variant only); fee in wei. */
  auto?: { enabled: boolean; interval: number; fee: bigint };
  /** Encrypted base rate (private variant only), as the contract's fixed-point unit. */
  unit?: bigint;
  /** What happens to the token after the mint, in this order. */
  donate?: { from: number; amount: bigint };
  accrue?: boolean;
  claim?: boolean;
  transferTo?: number;
};

const DAY = 86_400n;
const HOUR = 3_600n;
export const INDEFINITE = (1n << 64n) - 1n;
const MOCK = 10n ** 6n; // the mock token has 6 decimals
const ETH = 10n ** 9n; // cWETH has 9 decimals: one base unit is 1e9 wei
const perDay = (amount: bigint) => amount / DAY;
// The private-rate unit for `amount` base units per day at 100% (weight 1000).
const unitPerDay = (amount: bigint) => (amount << 32n) / (DAY * 1000n);

export const FIXTURES: Fixture[] = [
  // --- standard ENFT over the mock token ---
  { variant: "mock", name: "Steady stipend", creator: 0, owner: 0, amount: 1_000n * MOCK, startOffset: 0, topUps: false,
    segments: [{ duration: 30n * DAY, ratePerSec: perDay(30n * MOCK) }] }, // funded beyond the 900 it pays
  { variant: "mock", name: "Front-loaded gift", creator: 0, owner: 1, amount: 300n * MOCK, startOffset: 0, topUps: true,
    segments: [
      { duration: 7n * DAY, ratePerSec: perDay(50n * MOCK) },
      { duration: 14n * DAY, ratePerSec: perDay(20n * MOCK) },
      { duration: 30n * DAY, ratePerSec: perDay(5n * MOCK) },
    ], // pays 780 in all: underfunded even after the donation
    donate: { from: 2, amount: 100n * MOCK } },
  { variant: "mock", name: "Perpetual trickle", creator: 1, owner: 1, amount: 5_000n * MOCK, startOffset: 0, topUps: true,
    segments: [{ duration: INDEFINITE, ratePerSec: perDay(1n * MOCK) }] },
  { variant: "mock", name: "Starts next week", creator: 2, owner: 2, amount: 200n * MOCK, startOffset: Number(7n * DAY), topUps: true,
    segments: [{ duration: 10n * DAY, ratePerSec: perDay(20n * MOCK) }] },
  { variant: "mock", name: "Half way", creator: 2, owner: 3, amount: 600n * MOCK, startOffset: -Number(15n * DAY), topUps: false,
    segments: [{ duration: 30n * DAY, ratePerSec: perDay(20n * MOCK) }],
    accrue: true, claim: true },
  { variant: "mock", name: "Ended", creator: 3, owner: 3, amount: 50n * MOCK, startOffset: -Number(2n * DAY), topUps: false,
    segments: [{ duration: HOUR, ratePerSec: (50n * MOCK) / HOUR }],
    accrue: true }, // past its end: the accrual settles it
  { variant: "mock", name: "Run dry", creator: 3, owner: 0, amount: 10n * MOCK, startOffset: -Number(3n * DAY), topUps: true,
    segments: [{ duration: INDEFINITE, ratePerSec: perDay(10n * MOCK) }],
    accrue: true }, // three days at 10 a day against an endowment of 10
  { variant: "mock", name: "", creator: 4, owner: 4, amount: 1n, startOffset: 0, topUps: false,
    segments: [
      { duration: DAY, ratePerSec: 1n },
      { duration: 2n * DAY, ratePerSec: 0n }, // a pause
      { duration: INDEFINITE, ratePerSec: 1n },
    ] }, // unnamed, with the smallest possible endowment
  { variant: "mock", name: "Changed hands", creator: 4, owner: 4, amount: 120n * MOCK, startOffset: -Number(DAY), topUps: false,
    segments: [{ duration: 60n * DAY, ratePerSec: perDay(2n * MOCK) }],
    transferTo: 1 },
  { variant: "mock", name: "Many steps", creator: 1, owner: 2, amount: 2_400n * MOCK, startOffset: 0, topUps: true,
    segments: Array.from({ length: 24 }, (_, i) => ({ duration: 30n * DAY, ratePerSec: perDay(BigInt(i + 1) * MOCK) })) },

  // --- standard ENFT over wrapped ETH ---
  { variant: "wrapped", name: "ETH grant", creator: 0, owner: 0, amount: ETH / 2n, startOffset: 0, topUps: true,
    segments: [
      { duration: 30n * DAY, ratePerSec: perDay(ETH / 100n) },
      { duration: INDEFINITE, ratePerSec: perDay(ETH / 1000n) },
    ],
    donate: { from: 1, amount: ETH / 4n } },
  { variant: "wrapped", name: "Big reserve", creator: 1, owner: 2, amount: 25n * ETH, startOffset: 0, topUps: false,
    segments: [{ duration: 365n * DAY, ratePerSec: perDay(ETH / 20n) }] },
  { variant: "wrapped", name: "Dust", creator: 3, owner: 3, amount: 1_000n, startOffset: 0, topUps: false,
    segments: [{ duration: INDEFINITE, ratePerSec: 1n }] },

  // --- automatic payouts (wrapped ETH) ---
  { variant: "auto", name: "Daily payout", creator: 0, owner: 0, amount: ETH, startOffset: 0, topUps: true,
    segments: [{ duration: INDEFINITE, ratePerSec: perDay(ETH / 100n) }],
    auto: { enabled: true, interval: Number(DAY), fee: 10n ** 14n } },
  { variant: "auto", name: "Weekly no fee", creator: 2, owner: 1, amount: 2n * ETH, startOffset: -Number(8n * DAY), topUps: false,
    segments: [{ duration: 90n * DAY, ratePerSec: perDay(ETH / 50n) }],
    auto: { enabled: true, interval: Number(7n * DAY), fee: 0n } }, // a payout is due at once
  { variant: "auto", name: "Auto off", creator: 4, owner: 4, amount: (3n * ETH) / 10n, startOffset: 0, topUps: true,
    segments: [{ duration: 30n * DAY, ratePerSec: perDay(ETH / 100n) }],
    auto: { enabled: false, interval: Number(DAY), fee: 0n } },

  // --- private rate over the mock token: ratePerSec is a weight, 1000 = 100% ---
  { variant: "private", name: "Private stipend", creator: 0, owner: 0, amount: 1_000n * MOCK, startOffset: 0, topUps: false,
    unit: unitPerDay(1n * MOCK),
    segments: [{ duration: 30n * DAY, ratePerSec: 1000n }, { duration: INDEFINITE, ratePerSec: 500n }] },
  { variant: "private", name: "Private gift", creator: 1, owner: 3, amount: 500n * MOCK, startOffset: 0, topUps: true,
    unit: unitPerDay(5n * MOCK),
    segments: [{ duration: 90n * DAY, ratePerSec: 1000n }],
    donate: { from: 0, amount: 50n * MOCK } },
  { variant: "private", name: "Private zero rate", creator: 2, owner: 2, amount: 100n * MOCK, startOffset: 0, topUps: false,
    unit: 0n, // pays nothing until the end, then releases everything
    segments: [{ duration: 7n * DAY, ratePerSec: 1000n }] },
  { variant: "private", name: "Private steps", creator: 3, owner: 4, amount: 2_000n * MOCK, startOffset: -Number(5n * DAY), topUps: true,
    unit: unitPerDay(10n * MOCK),
    segments: [
      { duration: 10n * DAY, ratePerSec: 2000n },
      { duration: 10n * DAY, ratePerSec: 1000n },
      { duration: 10n * DAY, ratePerSec: 250n },
      { duration: INDEFINITE, ratePerSec: 100n },
    ],
    accrue: true },
];

export type FixtureResult = {
  variant: Variant;
  label: string | null; // null when no contract of this variant is deployed
  name: string;
  creator: string;
  owner: string; // the owner after any transfer
  tokenId: bigint | null;
  status: "created" | "exists" | "no contract";
};

const variantOf = (c: FixtureContract): Variant | null => {
  if (c.nftKind === "auto") return "auto";
  if (c.nftKind === "private") return c.tokenKind === "mock" ? "private" : null;
  return c.tokenKind === "mock" ? "mock" : c.tokenKind === "wrapped" ? "wrapped" : null;
};

const CONTRACT_NAME: Record<Variant, string> = {
  mock: "EndowmentNFT",
  wrapped: "EndowmentNFT",
  auto: "AutoPayoutEndowmentNFT",
  private: "PrivateRateEndowmentNFT",
};

const WETH_ABI = ["function deposit() payable", "function approve(address spender, uint256 amount) returns (bool)"];

/// Mints every fixture that does not exist yet. A fixture exists when its creator has
/// already minted a token of that name on the contract, so a second run adds nothing.
export async function createFixtures(
  hre: HardhatRuntimeEnvironment,
  contracts: FixtureContract[],
  fixtures: Fixture[] = FIXTURES,
): Promise<FixtureResult[]> {
  const { ethers, fhevm } = hre;
  const signers = await ethers.getSigners();
  const results: FixtureResult[] = [];

  // Puts `amount` of the contract's token in `who`'s balance and lets the NFT pull it.
  const fund = async (c: FixtureContract, who: (typeof signers)[number], amount: bigint) => {
    const now = (await ethers.provider.getBlock("latest"))!.timestamp;
    if (c.tokenKind === "mock") {
      const token = await ethers.getContractAt("MockConfidentialToken", c.token, who);
      await (await token.mint(who.address, amount)).wait();
      await (await token.setOperator(c.nft, now + 365 * 24 * 3600)).wait();
    } else {
      const token = await ethers.getContractAt("ConfidentialWETH", c.token, who);
      const wei = amount * (await token.rate());
      const weth = new ethers.Contract(await token.underlying(), WETH_ABI, who);
      await (await weth.deposit({ value: wei })).wait();
      await (await weth.approve(c.token, wei)).wait();
      await (await token.wrap(who.address, wei)).wait();
      await (await token.setOperator(c.nft, now + 365 * 24 * 3600)).wait();
    }
  };

  for (const variant of ["mock", "wrapped", "auto", "private"] as Variant[]) {
    const wanted = fixtures.filter((f) => f.variant === variant);
    const c = contracts.find((x) => variantOf(x) === variant);
    if (!c) {
      for (const f of wanted) {
        results.push({ variant, label: null, name: f.name, creator: signers[f.creator].address,
          owner: signers[f.transferTo ?? f.owner].address, tokenId: null, status: "no contract" });
      }
      continue;
    }
    const nft = await ethers.getContractAt(CONTRACT_NAME[variant], c.nft);
    const key = (creator: string, name: string) => `${creator.toLowerCase()}|${name}`;
    const existing = new Map<string, bigint>();
    for (const e of await nft.queryFilter(nft.filters.EndowmentMinted(), 0)) {
      const { tokenId, creator, name } = (e as any).args;
      existing.set(key(creator, name), tokenId);
    }

    for (const f of wanted) {
      const creator = signers[f.creator];
      const name = f.name ? ethers.encodeBytes32String(f.name) : ethers.ZeroHash;
      const base = { variant, label: c.label, name: f.name, creator: creator.address,
        owner: signers[f.transferTo ?? f.owner].address };
      const found = existing.get(key(creator.address, name));
      if (found !== undefined) {
        results.push({ ...base, tokenId: found, status: "exists" });
        continue;
      }

      await fund(c, creator, f.amount);
      const now = (await ethers.provider.getBlock("latest"))!.timestamp;
      const start = f.startOffset === 0 ? 0 : now + f.startOffset;
      const to = signers[f.owner].address;
      const input = fhevm.createEncryptedInput(c.nft, creator.address).add64(f.amount);
      if (variant === "private") input.add64(f.unit ?? 0n);
      const enc = await input.encrypt();
      const asCreator = nft.connect(creator) as any;
      const tx =
        variant === "private"
          ? await asCreator.mintPrivate(to, enc.handles[0], enc.handles[1], enc.inputProof, f.segments, start, f.topUps, name)
          : variant === "auto"
            ? await asCreator.mintAuto(to, enc.handles[0], enc.inputProof, f.segments, start, f.topUps, name,
                f.auto!.enabled, f.auto!.interval, f.auto!.fee)
            : await asCreator.mint(to, enc.handles[0], enc.inputProof, f.segments, start, f.topUps, name);
      const receipt = await tx.wait();
      let tokenId: bigint | null = null;
      for (const log of receipt.logs) {
        if (log.address.toLowerCase() !== c.nft.toLowerCase()) continue;
        const parsed = nft.interface.parseLog(log);
        if (parsed?.name === "EndowmentMinted") tokenId = parsed.args.tokenId;
      }
      if (tokenId === null) throw new Error(`no EndowmentMinted event for fixture "${f.name}" on ${c.label}`);

      if (f.donate) {
        const donor = signers[f.donate.from];
        await fund(c, donor, f.donate.amount);
        const gift = await fhevm.createEncryptedInput(c.nft, donor.address).add64(f.donate.amount).encrypt();
        await (await (nft.connect(donor) as any).topUp(tokenId, gift.handles[0], gift.inputProof)).wait();
      }
      if (f.accrue) await (await (nft.connect(creator) as any).accrue(tokenId)).wait();
      if (f.claim) await (await (nft.connect(signers[f.owner]) as any).claim(tokenId)).wait();
      if (f.transferTo !== undefined) {
        const owner = signers[f.owner];
        await (await (nft.connect(owner) as any).transferFrom(owner.address, signers[f.transferTo].address, tokenId)).wait();
      }
      results.push({ ...base, tokenId, status: "created" });
    }
  }
  return results;
}

// Human-readable ABI fragments for the contracts the browser talks to.

export const NFT_ABI = [
  "function mint(address to, bytes32 encEndowment, bytes inputProof, (uint64 duration, uint64 ratePerSec)[] segments, uint64 scheduleStart, bool topUpsAllowed, bytes32 name) returns (uint256)",
  "function topUp(uint256 tokenId, bytes32 encAmount, bytes inputProof)",
  "function claim(uint256 tokenId)",
  "function accrue(uint256 tokenId)",
  "function safeTransferFrom(address from, address to, uint256 tokenId)",
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function distributionHandle(uint256 tokenId) view returns (bytes32)",
  "event EndowmentMinted(uint256 indexed tokenId, address indexed creator, address indexed to, uint64 scheduleStart, bool topUpsAllowed, bytes32 name)",
  "error EmptySchedule()",
  "error ZeroDurationSegment()",
  "error IndefiniteSegmentNotLast()",
  "error ZeroRateIndefiniteSegment()",
  "error TopUpsDisabled()",
  "error NonexistentToken()",
  "error NotOwner()",
  "error ScheduleEnded()",
  "error ScheduleTooLong()",
  "error InvalidName()",
];

// The ENFT with automatic payouts: everything above, plus its own functions.
export const AUTO_NFT_ABI = [
  ...NFT_ABI,
  "function mintAuto(address to, bytes32 encEndowment, bytes inputProof, (uint64 duration, uint64 ratePerSec)[] segments, uint64 scheduleStart, bool topUpsAllowed, bytes32 name, bool enabled, uint32 interval, uint128 fee) returns (uint256)",
  "function setAutoPayout(uint256 tokenId, bool enabled, uint32 interval, uint128 fee)",
  "function autoPayoutOf(uint256 tokenId) view returns (bool enabled, uint32 interval, uint128 fee, uint64 lastRequestAt)",
  "function requestPayout(uint256 tokenId, uint128 minFee) returns (bytes32)",
  "function finalizePayout(uint256 tokenId, uint64 cleartextAmount, bytes decryptionProof)",
  "function pendingPayoutOf(uint256 tokenId) view returns (bytes32 requestId, address recipient, address requester, uint128 fee)",
  "function payoutDue(uint256 tokenId) view returns (bool)",
  "function lastPayoutOf(uint256 tokenId) view returns (uint64 paidAt, uint256 amountWei)",
  "event AutoPayoutSet(uint256 indexed tokenId, bool enabled, uint32 interval, uint128 fee)",
  "event PayoutRequested(uint256 indexed tokenId, bytes32 indexed requestId, address indexed recipient, address requester, uint128 fee)",
  "event PayoutPaid(uint256 indexed tokenId, bytes32 indexed requestId, uint256 amountWei, uint256 feeWei, bool paidInWeth)",
  "error InvalidInterval()",
  "error AutoPayoutDisabled()",
  "error PayoutPending()",
  "error PayoutTooSoon(uint64 notBefore)",
  "error ScheduleNotStarted()",
  "error NothingLeft()",
  "error FeeTooLow(uint128 fee)",
  "error NoPendingPayout()",
  "error InsufficientGas()",
  "error MintIdMismatch()",
  "error OnlyWeth()",
];

// ERC-7984, plus the mock token's faucet mint and the ERC-20 wrapper's functions.
export const TOKEN_ABI = [
  "function confidentialBalanceOf(address account) view returns (bytes32)",
  "function isOperator(address holder, address spender) view returns (bool)",
  "function setOperator(address operator, uint48 until)",
  "event OperatorSet(address indexed holder, address indexed operator, uint48 until)",
  "function mint(address to, uint64 amount)",
  "function wrap(address to, uint256 amount)",
  "function unwrap(address from, address to, bytes32 encAmount, bytes inputProof) returns (bytes32)",
  // The same, for an encrypted amount the caller already has access to.
  "function unwrap(address from, address to, bytes32 amount) returns (bytes32)",
  "event ConfidentialTransfer(address indexed from, address indexed to, bytes32 indexed amount)",
  "function finalizeUnwrap(bytes32 unwrapRequestId, uint64 unwrapAmountCleartext, bytes decryptionProof)",
  "function rate() view returns (uint256)",
  "function unwrapRequester(bytes32 unwrapRequestId) view returns (address)",
  "event UnwrapRequested(address indexed receiver, bytes32 indexed unwrapRequestId, bytes32 amount)",
];

export const WETH_ABI = [
  "function deposit() payable",
  "function withdraw(uint256 amount)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
];

// Human-readable ABI fragments for the contracts the browser talks to.

export const NFT_ABI = [
  "function mint(address to, bytes32 encEndowment, bytes inputProof, (uint64 duration, uint64 ratePerSec)[] segments, uint64 scheduleStart, bool topUpsAllowed) returns (uint256)",
  "function topUp(uint256 tokenId, bytes32 encAmount, bytes inputProof)",
  "function claim(uint256 tokenId)",
  "function accrue(uint256 tokenId)",
  "function safeTransferFrom(address from, address to, uint256 tokenId)",
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function distributionHandle(uint256 tokenId) view returns (bytes32)",
  "event EndowmentMinted(uint256 indexed tokenId, address indexed creator, address indexed to, uint64 scheduleStart, bool topUpsAllowed)",
  "error EmptySchedule()",
  "error ZeroDurationSegment()",
  "error IndefiniteSegmentNotLast()",
  "error ZeroRateIndefiniteSegment()",
  "error TopUpsDisabled()",
  "error NonexistentToken()",
  "error NotOwner()",
  "error ScheduleEnded()",
  "error ScheduleTooLong()",
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

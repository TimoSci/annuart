// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FhevmTest} from "forge-fhevm/FhevmTest.sol";
import {euint64, externalEuint64} from "encrypted-types/EncryptedTypes.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {ERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984ERC20Wrapper.sol";
import {MockConfidentialToken} from "../../src/mocks/MockConfidentialToken.sol";
import {MockWETH9} from "../../src/mocks/MockWETH9.sol";
import {ConfidentialWETH} from "../../src/ConfidentialWETH.sol";
import {EndowmentNFT} from "../../src/EndowmentNFT.sol";
import {AutoPayoutEndowmentNFT} from "../../src/AutoPayoutEndowmentNFT.sol";
import {Segment, INDEFINITE} from "../../src/libraries/Schedule.sol";

/// @dev Shared deployment and helpers for the red team suites. Two systems are deployed:
///      `enft` over the permissionless `mock` token, and `apnft` over `cweth`, which wraps
///      `weth` (a WETH9 copy, rate 1e9 wei per unit). Amounts are in token units throughout.
abstract contract RedTeamBase is FhevmTest {
    /// @dev Start time of every test, so that start times in the past can be expressed.
    uint64 internal constant T0 = 1_700_000_000;
    /// @dev Wei per cWETH unit.
    uint256 internal constant WEI_PER_UNIT = 1e9;

    MockConfidentialToken internal mock;
    EndowmentNFT internal enft;
    MockWETH9 internal weth;
    ConfidentialWETH internal cweth;
    AutoPayoutEndowmentNFT internal apnft;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");
    address internal donor = makeAddr("donor");
    address internal keeper = makeAddr("keeper");

    function setUp() public virtual override {
        super.setUp();
        vm.warp(T0);
        mock = new MockConfidentialToken();
        enft = new EndowmentNFT(IERC7984(address(mock)));
        weth = new MockWETH9();
        cweth = new ConfidentialWETH(IERC20(address(weth)));
        apnft = new AutoPayoutEndowmentNFT(ERC7984ERC20Wrapper(address(cweth)));
    }

    // ---- funding and authorisation ----

    /// @dev Mints `units` of the mock token to `who` (initialises the balance even when zero).
    function _fundMock(address who, uint64 units) internal {
        mock.mint(who, units);
    }

    /// @dev Gives `who` `units` cWETH the real way: ETH -> WETH -> wrap.
    function _fundCweth(address who, uint64 units) internal {
        uint256 amountWei = uint256(units) * WEI_PER_UNIT;
        vm.deal(who, who.balance + amountWei);
        vm.startPrank(who);
        weth.deposit{value: amountWei}();
        weth.approve(address(cweth), amountWei);
        cweth.wrap(who, amountWei);
        vm.stopPrank();
    }

    /// @dev `who` makes `nft` an operator of `who`'s balance in `nft`'s token for a year.
    function _authorise(address who, EndowmentNFT nft) internal {
        IERC7984 tok = nft.token(); // read first: vm.prank applies to the next call only
        vm.prank(who);
        tok.setOperator(address(nft), uint48(block.timestamp + 365 days));
    }

    /// @dev Encrypts `amount` as an input that only `sender` may submit, and only to `target`.
    function _enc(uint64 amount, address sender, address target) internal returns (externalEuint64, bytes memory) {
        return encryptUint64(amount, sender, target);
    }

    // ---- schedules ----

    /// @dev A one-segment schedule: `ratePerSec` units per second for `duration` seconds.
    function _seg(uint64 duration, uint64 ratePerSec) internal pure returns (Segment[] memory s) {
        s = new Segment[](1);
        s[0] = Segment({duration: duration, ratePerSec: ratePerSec});
    }

    /// @dev A one-segment schedule that never ends, at `ratePerSec`.
    function _forever(uint64 ratePerSec) internal pure returns (Segment[] memory s) {
        s = _seg(INDEFINITE, ratePerSec);
    }

    // ---- mint, topUp ----

    /// @dev `from` mints on `nft` with an input encrypted for `from`; funding and operator are the caller's job.
    function _mint(
        EndowmentNFT nft,
        address from,
        address to,
        uint64 amount,
        Segment[] memory segs,
        uint64 start,
        bool topUps,
        bytes32 name_
    ) internal returns (uint256 id) {
        (externalEuint64 h, bytes memory p) = _enc(amount, from, address(nft));
        vm.prank(from);
        id = nft.mint(to, h, p, segs, start, topUps, name_);
    }

    /// @dev `from` calls apnft.mintAuto with an input encrypted for `from`; funding and operator are the caller's job.
    function _mintAuto(
        address from,
        address to,
        uint64 amount,
        Segment[] memory segs,
        uint64 start,
        bool topUps,
        bytes32 name_,
        bool enabled,
        uint32 interval,
        uint128 fee
    ) internal returns (uint256 id) {
        (externalEuint64 h, bytes memory p) = _enc(amount, from, address(apnft));
        vm.prank(from);
        id = apnft.mintAuto(to, h, p, segs, start, topUps, name_, enabled, interval, fee);
    }

    /// @dev Funds `creator` with `amount` mock units, authorises, and mints to `to` at 1 unit/s for 1000 s from now.
    function _mintSimple(address to, uint64 amount, bool topUps) internal returns (uint256 id) {
        _fundMock(creator, amount);
        _authorise(creator, enft);
        id = _mint(enft, creator, to, amount, _seg(1000, 1), uint64(block.timestamp), topUps, bytes32(0));
    }

    /// @dev Funds `creator` with `units` cWETH, authorises, and mintAuto's to `to` at 1 unit/s for 1000 s from now.
    function _mintAutoSimple(address to, uint64 units, bool enabled, uint32 interval, uint128 fee)
        internal
        returns (uint256 id)
    {
        _fundCweth(creator, units);
        _authorise(creator, apnft);
        id = _mintAuto(creator, to, units, _seg(1000, 1), uint64(block.timestamp), false, bytes32(0), enabled, interval, fee);
    }

    /// @dev `from` tops up token `id` on `nft` with an input encrypted for `from`; funding and operator are the caller's job.
    function _topUp(EndowmentNFT nft, address from, uint256 id, uint64 amount) internal {
        (externalEuint64 h, bytes memory p) = _enc(amount, from, address(nft));
        vm.prank(from);
        nft.topUp(id, h, p);
    }

    // ---- payouts (apnft) ----

    /// @dev `who` requests a payout of token `id` with minFee 0; returns the request id.
    function _requestPayout(uint256 id, address who) internal returns (bytes32 rid) {
        rid = _requestPayout(id, who, 0);
    }

    /// @dev `who` requests a payout of token `id`, refusing a fee below `minFee`; returns the request id.
    function _requestPayout(uint256 id, address who, uint128 minFee) internal returns (bytes32 rid) {
        vm.prank(who);
        rid = apnft.requestPayout(id, minFee);
    }

    /// @dev The cleartext of request `rid` and a KMS decryption proof for it.
    function _decryptionProof(bytes32 rid) internal returns (uint64 clear, bytes memory proof) {
        clear = uint64(decrypt(rid));
        proof = buildDecryptionProof(rid, abi.encode(clear));
    }

    /// @dev `who` finalises the pending payout of token `id` with a valid proof; returns the units paid.
    function _finalizePayout(uint256 id, address who) internal returns (uint64 clear) {
        (bytes32 rid,,,) = apnft.pendingPayoutOf(id);
        bytes memory proof;
        (clear, proof) = _decryptionProof(rid);
        vm.prank(who);
        apnft.finalizePayout(id, clear, proof);
    }

    /// @dev Request by `requester`, then finalise by `finaliser`; returns the units paid.
    function _payoutRoundTrip(uint256 id, address requester, address finaliser) internal returns (uint64 clear) {
        _requestPayout(id, requester);
        clear = _finalizePayout(id, finaliser);
    }

    // ---- reading encrypted values (test oracle: ignores the ACL) ----

    /// @dev The plaintext of `who`'s balance in `tok`.
    function _bal(IERC7984 tok, address who) internal returns (uint64) {
        return decrypt(tok.confidentialBalanceOf(who));
    }

    /// @dev The plaintext of token `id`'s claimable distribution on `nft`.
    function _dist(EndowmentNFT nft, uint256 id) internal returns (uint64) {
        return decrypt(nft.distributionHandle(id));
    }

    /// @dev The plaintext of token `id`'s remaining (secret) endowment on `nft`.
    function _endow(EndowmentNFT nft, uint256 id) internal returns (uint64) {
        return decrypt(nft.endowmentHandle(id));
    }

    /// @dev Whether the host ACL lets `who` use handle `h` (persistent or transient).
    function _allowed(euint64 h, address who) internal view returns (bool) {
        return _acl.isAllowed(euint64.unwrap(h), who);
    }

    /// @dev Whether the host ACL lets `who` use handle `h` PERSISTENTLY. This is the grant
    ///      off-chain user-decryption requires (FhevmTest/plugin check persistAllowed); a
    ///      transient grant that lives only inside one transaction does not enable it.
    function _persistAllowed(euint64 h, address who) internal view returns (bool) {
        return _acl.persistAllowed(euint64.unwrap(h), who);
    }

    /// @dev Whether handle `h` has been made publicly decryptable (FHE.makePubliclyDecryptable).
    function _publicDecryptable(euint64 h) internal view returns (bool) {
        return _acl.isAllowedForDecryption(euint64.unwrap(h));
    }

    /// @dev Whether the raw handle `h` (e.g. a payout request id) is publicly decryptable.
    function _publicDecryptable(bytes32 h) internal view returns (bool) {
        return _acl.isAllowedForDecryption(h);
    }
}

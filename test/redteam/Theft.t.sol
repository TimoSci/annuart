// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ACL} from "@fhevm/host-contracts/contracts/ACL.sol";
import {InputVerifier} from "@fhevm/host-contracts/contracts/InputVerifier.sol";
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {ERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984ERC20Wrapper.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RedTeamBase} from "./RedTeamBase.sol";
import {EndowmentNFT} from "../../src/EndowmentNFT.sol";
import {AutoPayoutEndowmentNFT} from "../../src/AutoPayoutEndowmentNFT.sol";
import {Segment} from "../../src/libraries/Schedule.sol";

/// @dev An ERC-721 receiver and ETH receiver that, when armed, calls back into the NFT
///      contract from onERC721Received and/or receive, and records how each call ended.
///      Calls are chosen by a bit mask; results are packed into one storage slot so the
///      ETH path fits in the payout's 100k-gas stipend.
contract Reenterer {
    uint8 internal constant CLAIM = 0;
    uint8 internal constant TOPUP = 1;
    uint8 internal constant MINT = 2;
    uint8 internal constant REQUEST = 3;
    uint8 internal constant MINT_AUTO = 4;
    uint8 internal constant FINALIZE = 5;
    uint8 internal constant CLAIM_AGAIN = 6;
    /// @dev Recorded for a call that succeeded.
    bytes4 internal constant OK = 0xffffffff;

    address internal immutable nft;
    uint256 internal mask;
    bool internal onNft;
    bool internal onEth;
    uint256 public tokenId;
    externalEuint64 internal h;
    bytes internal p;
    bytes32 public results;

    constructor(address nft_) {
        nft = nft_;
    }

    /// @param h_ and p_ an input encrypted for this contract and `nft`, used by mint, mintAuto and topUp.
    function arm(uint256 mask_, bool onNft_, bool onEth_, externalEuint64 h_, bytes calldata p_) external {
        mask = mask_;
        onNft = onNft_;
        onEth = onEth_;
        h = h_;
        p = p_;
    }

    function resultOf(uint8 i) external view returns (bytes4) {
        // casting to bytes4 is safe: it takes the i-th packed selector, moved to the top
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(results << (32 * uint256(i)));
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        tokenId = id;
        if (onNft) _attack(id);
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (onEth) _attack(tokenId);
    }

    function _attack(uint256 id) internal {
        externalEuint64 hh = h;
        bytes memory proof = p;
        uint256 m = mask;
        bytes32 r;
        for (uint8 i = 0; i < 8; i++) {
            if ((m >> i) & 1 == 1) r |= bytes32(_call(i, id, hh, proof)) >> (32 * uint256(i));
        }
        results = r;
    }

    function _call(uint8 i, uint256 id, externalEuint64 hh, bytes memory proof) internal returns (bytes4) {
        Segment[] memory s = new Segment[](1);
        s[0] = Segment({duration: 1000, ratePerSec: 1});
        bytes memory data;
        if (i == CLAIM || i == CLAIM_AGAIN) {
            data = abi.encodeCall(EndowmentNFT.claim, (id));
        } else if (i == TOPUP) {
            data = abi.encodeCall(EndowmentNFT.topUp, (id, hh, proof));
        } else if (i == MINT) {
            data = abi.encodeCall(EndowmentNFT.mint, (address(this), hh, proof, s, 0, true, bytes32(0)));
        } else if (i == REQUEST) {
            data = abi.encodeCall(AutoPayoutEndowmentNFT.requestPayout, (id, 0));
        } else if (i == MINT_AUTO) {
            data = abi.encodeCall(
                AutoPayoutEndowmentNFT.mintAuto, (address(this), hh, proof, s, 0, true, bytes32(0), true, 3600, 0)
            );
        } else {
            data = abi.encodeCall(AutoPayoutEndowmentNFT.finalizePayout, (id, 0, ""));
        }
        (bool ok, bytes memory ret) = nft.call(data);
        if (ok) return OK;
        // casting to bytes4 is safe: only the error selector is wanted
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(ret);
    }
}

/// @dev Stands in for the cWETH wrapper of an AutoPayoutEndowmentNFT, so that the token call
///      inside mintAuto is attacker code. During confidentialTransferFrom it tries to mint
///      on the NFT contract (which would move _nextId and trip MintIdMismatch), then hands
///      back the requested amount as if it had moved it.
contract ReenteringWrapper {
    AutoPayoutEndowmentNFT internal nft;
    externalEuint64 internal h;
    bytes internal p;
    bytes4 public mintError;
    bytes4 public mintAutoError;
    uint256 public calls;

    function underlying() external pure returns (address) {
        return address(0xEEEE);
    }

    function rate() external pure returns (uint256) {
        return 1;
    }

    function setTarget(AutoPayoutEndowmentNFT nft_, externalEuint64 h_, bytes calldata p_) external {
        nft = nft_;
        h = h_;
        p = p_;
    }

    function confidentialTransferFrom(address, address, euint64 amount) external returns (euint64) {
        calls++;
        Segment[] memory s = new Segment[](1);
        s[0] = Segment({duration: 1000, ratePerSec: 1});
        try nft.mint(address(this), h, p, s, 0, false, bytes32(0)) {}
        catch (bytes memory err) {
            // casting to bytes4 is safe: only the error selector is wanted
            // forge-lint: disable-next-line(unsafe-typecast)
            mintError = bytes4(err);
        }
        try nft.mintAuto(address(this), h, p, s, 0, false, bytes32(0), false, 3600, 0) {}
        catch (bytes memory err) {
            // casting to bytes4 is safe: only the error selector is wanted
            // forge-lint: disable-next-line(unsafe-typecast)
            mintAutoError = bytes4(err);
        }
        return amount; // the NFT contract is transiently allowed on it (from fromExternal)
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @dev Task 2 of the red team: theft through deposits (mint, mintAuto, topUp) and claims.
contract TheftTest is RedTeamBase {
    uint256 internal constant M_CLAIM = 1 << 0;
    uint256 internal constant M_TOPUP = 1 << 1;
    uint256 internal constant M_MINT = 1 << 2;
    uint256 internal constant M_REQUEST = 1 << 3;
    uint256 internal constant M_MINT_AUTO = 1 << 4;
    uint256 internal constant M_FINALIZE = 1 << 5;
    uint256 internal constant M_CLAIM_AGAIN = 1 << 6;
    bytes4 internal constant OK = 0xffffffff;
    bytes4 internal immutable REENTRY = ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
    uint64 internal constant MAX = type(uint64).max;

    /// @dev A Reenterer on `nft`, holding `units` of `nft`'s token with `nft` as its operator.
    function _reenterer(EndowmentNFT nft, uint64 units) internal returns (Reenterer r) {
        r = new Reenterer(address(nft));
        if (nft == enft) _fundMock(address(r), units);
        else _fundCweth(address(r), units);
        _authorise(address(r), nft);
    }

    /// @dev Arms `r` with `mask`, giving it a valid input of 1 unit for its own mint/topUp calls.
    function _arm(Reenterer r, EndowmentNFT nft, uint256 mask, bool onNft, bool onEth) internal {
        (externalEuint64 h, bytes memory p) = _enc(1, address(r), address(nft));
        r.arm(mask, onNft, onEth, h, p);
    }

    // =====================================================================
    // C2-2 Under-funded deposits
    // =====================================================================

    /// Mint asking for more than the creator holds: the token is credited zero, and it
    /// cannot draw on another token's funds in the same pool.
    function test_C2_2_mintAboveBalance_creditsZeroAndCannotDrawOnPool() public {
        _fundMock(creator, 100);
        _authorise(creator, enft);
        uint256 a = _mint(enft, creator, alice, 500, _seg(1000, 1), uint64(block.timestamp), false, bytes32(0));
        assertEq(_endow(enft, a), 0, "under-funded token credited");
        assertEq(_bal(mock, creator), 100, "creator lost funds");
        assertEq(_bal(mock, address(enft)), 0, "pool after under-funded mint");

        uint256 b = _mintSimple(bob, 1000, false); // a properly funded neighbour
        assertEq(_endow(enft, b), 1000);

        vm.warp(block.timestamp + 2000); // both schedules over: everything left is released
        vm.prank(alice);
        enft.claim(a);
        vm.prank(bob);
        enft.claim(b);
        assertEq(_bal(mock, alice), 0, "under-funded token paid out");
        assertEq(_bal(mock, bob), 1000, "neighbour short-changed");
        assertEq(_bal(mock, address(enft)), 0, "pool");
    }

    /// TopUp asking for more than the donor holds is all-or-nothing: zero is added, not the
    /// part the donor had.
    function test_C2_2_topUpAboveBalance_creditsZero() public {
        uint256 id = _mintSimple(alice, 500, true);
        _fundMock(donor, 50);
        _authorise(donor, enft);
        _topUp(enft, donor, id, 300);
        assertEq(_endow(enft, id), 500, "top-up credited more than moved");
        assertEq(_bal(mock, donor), 50, "donor charged");
        assertEq(_bal(mock, address(enft)), 500, "pool");

        vm.warp(block.timestamp + 2000);
        vm.prank(alice);
        enft.claim(id);
        assertEq(_bal(mock, alice), 500);
        assertEq(_bal(mock, address(enft)), 0);
    }

    /// A sender whose balance exists but is zero mints and tops up a token worth zero.
    function test_C2_2_zeroBalance_creditsZero() public {
        uint256 id = _mintSimple(alice, 500, true);
        _fundMock(mallory, 0); // initialised, zero
        _authorise(mallory, enft);
        uint256 m = _mint(enft, mallory, mallory, 1000, _seg(1000, 1), uint64(block.timestamp), true, bytes32(0));
        _topUp(enft, mallory, id, 1000);
        assertEq(_endow(enft, m), 0, "zero-balance mint credited");
        assertEq(_endow(enft, id), 500, "zero-balance top-up credited");
        assertEq(_bal(mock, address(enft)), 500, "pool");

        vm.warp(block.timestamp + 2000);
        vm.prank(mallory);
        enft.claim(m);
        assertEq(_bal(mock, mallory), 0, "attacker drew on the pool");
    }

    /// A sender that never held the token cannot mint or top up at all.
    function test_C2_2_neverFundedSender_reverts() public {
        uint256 id = _mintSimple(alice, 500, true);
        _authorise(mallory, enft);
        (externalEuint64 h, bytes memory p) = _enc(1000, mallory, address(enft));
        vm.expectRevert(abi.encodeWithSelector(ERC7984.ERC7984ZeroBalance.selector, mallory));
        vm.prank(mallory);
        enft.mint(mallory, h, p, _seg(1000, 1), 0, false, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(ERC7984.ERC7984ZeroBalance.selector, mallory));
        vm.prank(mallory);
        enft.topUp(id, h, p);
    }

    /// Schedule validation at deposit time (coverage: EndowmentNFT.sol:77 and :112).
    function test_C2_2a_mintEmptySchedule_reverts() public {
        _fundMock(creator, 500);
        _authorise(creator, enft);
        (externalEuint64 h, bytes memory p) = _enc(500, creator, address(enft));
        vm.expectRevert(EndowmentNFT.EmptySchedule.selector);
        vm.prank(creator);
        enft.mint(alice, h, p, new Segment[](0), 0, false, bytes32(0));
        assertEq(_bal(mock, creator), 500);
    }

    function test_C2_2a_mintZeroDurationSegment_reverts() public {
        _fundMock(creator, 500);
        _authorise(creator, enft);
        (externalEuint64 h, bytes memory p) = _enc(500, creator, address(enft));
        vm.expectRevert(EndowmentNFT.ZeroDurationSegment.selector);
        vm.prank(creator);
        enft.mint(alice, h, p, _seg(0, 1), 0, false, bytes32(0));

        // a zero-duration segment after a valid one is refused too
        Segment[] memory s = new Segment[](2);
        s[0] = Segment({duration: 100, ratePerSec: 1});
        s[1] = Segment({duration: 0, ratePerSec: 1_000_000});
        vm.expectRevert(EndowmentNFT.ZeroDurationSegment.selector);
        vm.prank(creator);
        enft.mint(alice, h, p, s, 0, false, bytes32(0));
        assertEq(_bal(mock, creator), 500);
    }

    /// Pre-funding the id that the next mint will get is refused (coverage: EndowmentNFT.sol:214),
    /// so a donor's money cannot end up in a token whose terms are not yet known.
    function test_C2_2b_topUpFutureId_reverts() public {
        _fundMock(donor, 300);
        _authorise(donor, enft);
        (externalEuint64 h, bytes memory p) = _enc(300, donor, address(enft));
        vm.expectRevert(EndowmentNFT.NonexistentToken.selector);
        vm.prank(donor);
        enft.topUp(1, h, p);

        uint256 id = _mintSimple(alice, 500, true);
        assertEq(id, 1);
        assertEq(_endow(enft, id), 500, "future id was pre-funded");
        assertEq(_bal(mock, donor), 300);
    }

    /// topUpsAllowedOf reports the mode, and gates topUp (coverage: EndowmentNFT.sol:194-195).
    function test_C2_2c_topUpsAllowedOf_matchesTopUpGate() public {
        uint256 locked = _mintSimple(alice, 500, false);
        uint256 open = _mintSimple(alice, 500, true);
        assertFalse(enft.topUpsAllowedOf(locked));
        assertTrue(enft.topUpsAllowedOf(open));
        assertFalse(enft.topUpsAllowedOf(99), "nonexistent token: false, no revert");

        _fundMock(donor, 100);
        _authorise(donor, enft);
        (externalEuint64 h, bytes memory p) = _enc(100, donor, address(enft));
        vm.expectRevert(EndowmentNFT.TopUpsDisabled.selector);
        vm.prank(donor);
        enft.topUp(locked, h, p);
        _topUp(enft, donor, open, 100);
        assertEq(_endow(enft, open), 600);
    }

    // =====================================================================
    // C2-3 Spending someone else's tokens
    // =====================================================================

    /// The victim has made the NFT contract an operator; the attacker mints asking for the
    /// victim's balance. Only the attacker's own (empty) balance is touched.
    function test_C2_3_attackerMintCannotPullOperatorVictimFunds() public {
        _fundMock(alice, 1000);
        _authorise(alice, enft);
        _fundMock(mallory, 0);
        _authorise(mallory, enft);

        uint256 m = _mint(enft, mallory, mallory, 1000, _seg(10, 100), uint64(block.timestamp), false, bytes32(0));
        assertEq(_bal(mock, alice), 1000, "victim's funds pulled");
        assertEq(_endow(enft, m), 0);
        assertEq(_bal(mock, address(enft)), 0);
    }

    function test_C2_3_attackerTopUpCannotPullOperatorVictimFunds() public {
        _fundMock(alice, 1000);
        _authorise(alice, enft);
        uint256 id = _mintSimple(mallory, 10, true); // the attacker's own token
        _fundMock(mallory, 0);
        _authorise(mallory, enft);

        _topUp(enft, mallory, id, 1000);
        assertEq(_bal(mock, alice), 1000, "victim's funds pulled");
        assertEq(_endow(enft, id), 10);
    }

    /// Same on cWETH through mintAuto and topUp.
    function test_C2_3_attackerMintAutoCannotPullOperatorVictimCweth() public {
        _fundCweth(alice, 1000);
        _authorise(alice, apnft);
        _fundCweth(mallory, 1);
        _authorise(mallory, apnft);

        uint256 m = _mintAuto(
            mallory, mallory, 1000, _seg(10, 100), uint64(block.timestamp), true, bytes32(0), true, 3600, 0
        );
        _topUp(apnft, mallory, m, 1000);
        assertEq(_bal(cweth, alice), 1000, "victim's cWETH pulled");
        assertEq(_bal(cweth, mallory), 1, "attacker charged a partial amount");
        assertEq(_endow(apnft, m), 0);
        assertEq(_bal(cweth, address(apnft)), 0);
    }

    // =====================================================================
    // C2-4 Encrypted input misuse
    // =====================================================================

    /// The attacker replays the victim's (handle, inputProof) in mint and topUp, before and
    /// after the victim used it; the input is bound to the victim as sender.
    function test_C2_4_replayVictimInput_reverts() public {
        _fundMock(alice, 1000);
        _authorise(alice, enft);
        _fundMock(mallory, 1000);
        _authorise(mallory, enft);
        uint256 id = _mintSimple(bob, 10, true);
        (externalEuint64 h, bytes memory p) = _enc(1000, alice, address(enft));

        vm.expectPartialRevert(InputVerifier.InvalidSigner.selector);
        vm.prank(mallory);
        enft.mint(mallory, h, p, _seg(1000, 1), 0, false, bytes32(0));
        vm.expectPartialRevert(InputVerifier.InvalidSigner.selector);
        vm.prank(mallory);
        enft.topUp(id, h, p);

        vm.prank(alice);
        enft.mint(alice, h, p, _seg(1000, 1), 0, false, bytes32(0)); // the victim uses it

        vm.expectPartialRevert(InputVerifier.InvalidSigner.selector);
        vm.prank(mallory);
        enft.mint(mallory, h, p, _seg(1000, 1), 0, false, bytes32(0));
        // the used input handle, with no proof, is not usable by the attacker either
        vm.expectRevert(
            abi.encodeWithSelector(FHE.SenderNotAllowedToUseHandle.selector, externalEuint64.unwrap(h), mallory)
        );
        vm.prank(mallory);
        enft.mint(mallory, h, "", _seg(1000, 1), 0, false, bytes32(0));

        assertEq(_bal(mock, mallory), 1000, "attacker balance moved");
        assertEq(_bal(mock, alice), 0);
        assertEq(_endow(enft, 2), 1000);
    }

    /// An input made for another contract (the other NFT contract, or the token itself) is refused.
    function test_C2_4_inputForOtherContract_reverts() public {
        _fundMock(mallory, 1000);
        _authorise(mallory, enft);
        _fundCweth(mallory, 1000);
        _authorise(mallory, apnft);
        uint256 id = _mintSimple(bob, 10, true);

        (externalEuint64 hAp, bytes memory pAp) = _enc(1000, mallory, address(apnft));
        vm.expectPartialRevert(InputVerifier.InvalidSigner.selector);
        vm.prank(mallory);
        enft.mint(mallory, hAp, pAp, _seg(1000, 1), 0, false, bytes32(0));

        (externalEuint64 hTok, bytes memory pTok) = _enc(1000, mallory, address(mock));
        vm.expectPartialRevert(InputVerifier.InvalidSigner.selector);
        vm.prank(mallory);
        enft.topUp(id, hTok, pTok);

        (externalEuint64 hE, bytes memory pE) = _enc(1000, mallory, address(enft));
        vm.expectPartialRevert(InputVerifier.InvalidSigner.selector);
        vm.prank(mallory);
        apnft.mintAuto(mallory, hE, pE, _seg(1000, 1), 0, false, bytes32(0), true, 3600, 0);

        assertEq(_bal(mock, mallory), 1000);
        assertEq(_bal(cweth, mallory), 1000);
    }

    /// Existing handles passed as the external input with an empty proof: a victim's balance,
    /// another token's distribution and endowmentRemaining, and the attacker's own balance
    /// (which the NFT contract may not use).
    function test_C2_4_existingHandleAsInput_reverts() public {
        _fundMock(alice, 1000);
        _fundMock(mallory, 1000);
        _authorise(mallory, enft);
        uint256 id = _mintSimple(bob, 500, true);
        vm.warp(block.timestamp + 100);
        enft.accrue(id);

        bytes32[3] memory foreign = [
            euint64.unwrap(mock.confidentialBalanceOf(alice)),
            euint64.unwrap(enft.distributionHandle(id)),
            euint64.unwrap(enft.endowmentHandle(id))
        ];
        for (uint256 i = 0; i < foreign.length; i++) {
            externalEuint64 h = externalEuint64.wrap(foreign[i]);
            vm.expectRevert(abi.encodeWithSelector(FHE.SenderNotAllowedToUseHandle.selector, foreign[i], mallory));
            vm.prank(mallory);
            enft.mint(mallory, h, "", _seg(1000, 1), 0, false, bytes32(0));
            vm.expectRevert(abi.encodeWithSelector(FHE.SenderNotAllowedToUseHandle.selector, foreign[i], mallory));
            vm.prank(mallory);
            enft.topUp(id, h, "");
        }

        externalEuint64 own = externalEuint64.wrap(euint64.unwrap(mock.confidentialBalanceOf(mallory)));
        vm.expectRevert(abi.encodeWithSelector(ACL.SenderNotAllowed.selector, address(enft)));
        vm.prank(mallory);
        enft.mint(mallory, own, "", _seg(1000, 1), 0, false, bytes32(0));

        assertEq(_bal(mock, mallory), 1000);
        assertEq(_bal(mock, alice), 1000);
        assertEq(_endow(enft, id), 400);
        assertEq(_dist(enft, id), 100);
    }

    /// A handle that both the caller and the NFT contract may use (the caller's own token's
    /// distribution) is accepted with no proof, but it only sets the amount: the funds still
    /// come from the caller, and the source token is untouched.
    function test_C2_4a_ownDistributionAsInput_pullsOnlyCallerFunds() public {
        uint256 src = _mintSimple(mallory, 500, true);
        vm.warp(block.timestamp + 100);
        enft.accrue(src); // distribution 100, readable by mallory and the NFT contract
        _fundMock(mallory, 1000);
        _authorise(mallory, enft);
        _fundMock(alice, 1000);
        _authorise(alice, enft);

        externalEuint64 h = externalEuint64.wrap(euint64.unwrap(enft.distributionHandle(src)));
        vm.prank(mallory);
        uint256 m = enft.mint(mallory, h, "", _seg(1000, 1), 0, false, bytes32(0));
        vm.prank(mallory);
        enft.topUp(src, h, "");

        assertEq(_endow(enft, m), 100);
        assertEq(_endow(enft, src), 500); // 400 left + 100 topped up by mallory
        assertEq(_bal(mock, mallory), 800, "both deposits came from the caller");
        assertEq(_bal(mock, alice), 1000);
        assertEq(_dist(enft, src), 100, "source distribution touched");
        assertEq(_bal(mock, address(enft)), 500 + 200);
    }

    // =====================================================================
    // C2-5 Claim paths
    // (non-owner claim: test_claim_onlyOwner in test/EndowmentNFT.t.sol)
    // =====================================================================

    function test_C2_5_claimByApprovedOperator_reverts() public {
        uint256 id = _mintSimple(alice, 500, false);
        vm.startPrank(alice);
        enft.approve(bob, id);
        enft.setApprovalForAll(mallory, true);
        vm.stopPrank();
        vm.warp(block.timestamp + 100);

        vm.expectRevert(EndowmentNFT.NotOwner.selector);
        vm.prank(bob);
        enft.claim(id);
        vm.expectRevert(EndowmentNFT.NotOwner.selector);
        vm.prank(mallory);
        enft.claim(id);

        vm.prank(alice);
        enft.claim(id);
        assertEq(_bal(mock, alice), 100);
    }

    function test_C2_5_claimByPreviousOwner_reverts() public {
        uint256 id = _mintSimple(alice, 500, false);
        vm.warp(block.timestamp + 100);
        enft.accrue(id); // 100 accrued while alice owned it
        vm.prank(alice);
        enft.transferFrom(alice, bob, id);

        vm.expectRevert(EndowmentNFT.NotOwner.selector);
        vm.prank(alice);
        enft.claim(id);

        vm.prank(bob);
        enft.claim(id);
        assertEq(_bal(mock, bob), 100);
        assertEq(_bal(mock, alice), 0);
    }

    function test_C2_5_claimTwiceSameBlock_paysOnce() public {
        uint256 id = _mintSimple(alice, 500, false);
        vm.warp(block.timestamp + 100);
        vm.startPrank(alice);
        enft.claim(id);
        enft.claim(id);
        vm.stopPrank();
        assertEq(_bal(mock, alice), 100);
        assertEq(_bal(mock, address(enft)), 400);
        assertEq(_endow(enft, id), 400);
        assertEq(_dist(enft, id), 0);
    }

    /// The new owner re-enters claim, mint and topUp from onERC721Received during mint, on a
    /// token whose schedule is already over (so a claim would pay everything).
    function test_C2_5_reenterFromMintReceiver_blocked() public {
        Reenterer r = _reenterer(enft, 100);
        _arm(r, enft, M_CLAIM | M_TOPUP | M_MINT, true, false);
        _fundMock(creator, 500);
        _authorise(creator, enft);
        uint256 id = _mint(enft, creator, address(r), 500, _seg(1000, 1), T0 - 2000, true, bytes32(0));

        assertEq(r.resultOf(0), REENTRY, "claim");
        assertEq(r.resultOf(1), REENTRY, "topUp");
        assertEq(r.resultOf(2), REENTRY, "mint");
        assertEq(_bal(mock, address(r)), 100, "paid during mint");
        assertEq(enft.balanceOf(address(r)), 1);

        vm.prank(address(r));
        enft.claim(id);
        assertEq(_bal(mock, address(r)), 600);
        assertEq(_bal(mock, address(enft)), 0);
    }

    /// As above for mintAuto, adding requestPayout and mintAuto. The id staged by mintAuto
    /// cannot be taken by a mint inside the receiver callback (MintIdMismatch, AP.sol:121).
    function test_C2_5a_mintAutoReceiverReentry_cannotChangeId() public {
        Reenterer r = _reenterer(apnft, 100);
        _arm(r, apnft, M_CLAIM | M_TOPUP | M_MINT | M_REQUEST | M_MINT_AUTO, true, false);
        _fundCweth(creator, 500);
        _authorise(creator, apnft);
        uint256 id = _mintAuto(
            creator, address(r), 500, _seg(1000, 1), T0 - 2000, true, bytes32(0), true, 3600, 0
        );

        for (uint8 i = 0; i < 5; i++) {
            assertEq(r.resultOf(i), REENTRY);
        }
        assertEq(id, 1);
        assertEq(apnft.totalMinted(), 1, "a second token was minted inside mintAuto");
        (bool enabled, uint32 interval,,) = apnft.autoPayoutOf(id);
        assertTrue(enabled);
        assertEq(interval, 3600);
        (bytes32 rid,,,) = apnft.pendingPayoutOf(id);
        assertEq(rid, bytes32(0), "payout requested during mint");
        assertEq(_bal(cweth, address(r)), 100, "paid during mint");
    }

    /// The only other call-out inside mintAuto is the token. With a wrapper that is attacker
    /// code and re-enters mint and mintAuto during confidentialTransferFrom, the id still
    /// cannot change: both re-entries hit the reentrancy guard.
    function test_C2_5b_mintAutoTokenReentry_cannotChangeId() public {
        ReenteringWrapper w = new ReenteringWrapper();
        AutoPayoutEndowmentNFT evil = new AutoPayoutEndowmentNFT(ERC7984ERC20Wrapper(address(w)));
        (externalEuint64 hw, bytes memory pw) = _enc(1, address(w), address(evil));
        w.setTarget(evil, hw, pw);

        (externalEuint64 h, bytes memory p) = _enc(500, creator, address(evil));
        vm.prank(creator);
        uint256 id = evil.mintAuto(alice, h, p, _seg(1000, 1), 0, false, bytes32(0), true, 3600, 0);

        assertEq(w.calls(), 1, "token was called");
        assertEq(w.mintError(), REENTRY);
        assertEq(w.mintAutoError(), REENTRY);
        assertEq(id, 1);
        assertEq(evil.totalMinted(), 1);
        assertEq(evil.ownerOf(1), alice);
    }

    /// A contract receiving the token by safeTransferFrom claims twice from its callback: it is
    /// the current owner, so the claim pays it, once; the previous owner gets nothing more.
    function test_C2_5_reenterFromTransferReceiver_paysCurrentOwnerOnce() public {
        uint256 id = _mintSimple(alice, 500, false);
        Reenterer r = new Reenterer(address(enft));
        _arm(r, enft, M_CLAIM | M_CLAIM_AGAIN, true, false);
        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        enft.safeTransferFrom(alice, address(r), id);

        assertEq(r.resultOf(0), OK);
        assertEq(r.resultOf(6), OK);
        assertEq(_bal(mock, address(r)), 100, "claimed other than once");
        assertEq(_bal(mock, alice), 0);
        assertEq(_bal(mock, address(enft)), 400);
    }

    /// Recipient and requester both re-enter every state-changing function from their ETH
    /// receive during finalizePayout. All are blocked, and each is paid exactly once in ETH.
    function test_C2_5_reenterFromEthReceive_blocked() public {
        Reenterer owner_ = _reenterer(apnft, 10);
        Reenterer requester = _reenterer(apnft, 10);
        uint256 all = M_CLAIM | M_TOPUP | M_MINT | M_REQUEST | M_MINT_AUTO | M_FINALIZE;
        _arm(owner_, apnft, all, false, true);
        _arm(requester, apnft, all, false, true);
        _fundCweth(creator, 1000);
        _authorise(creator, apnft);
        uint256 id = _mintAuto(
            creator, address(owner_), 1000, _seg(1000, 1), uint64(block.timestamp), true, bytes32(0), true, 3600, 1e10
        );
        vm.warp(block.timestamp + 1000);

        uint64 units = _payoutRoundTrip(id, address(requester), keeper);

        assertEq(units, 1000);
        for (uint8 i = 0; i < 6; i++) {
            assertEq(owner_.resultOf(i), REENTRY, "recipient re-entry");
            assertEq(requester.resultOf(i), REENTRY, "requester re-entry");
        }
        assertEq(address(owner_).balance, 1000 * WEI_PER_UNIT - 1e10, "recipient ETH");
        assertEq(address(requester).balance, 1e10, "requester ETH");
        assertEq(weth.balanceOf(address(owner_)), 0, "paid in WETH instead");
        assertEq(apnft.totalMinted(), 1);
        (bytes32 rid,,,) = apnft.pendingPayoutOf(id);
        assertEq(rid, bytes32(0));
        assertEq(_bal(cweth, address(owner_)), 10);
        assertEq(_bal(cweth, address(requester)), 10);
        assertEq(_bal(cweth, address(apnft)), 0);
    }

    // =====================================================================
    // C2-6 Arithmetic limits
    // =====================================================================

    /// Drive one token's endowment to type(uint64).max with mint plus topUp, try to push it
    /// over, then release it in two accruals plus the end-of-schedule sweep: nothing wraps.
    function test_C2_6_endowmentAtUint64Max_noWrap() public {
        _fundMock(creator, MAX - 10);
        _authorise(creator, enft);
        uint256 id = _mint(enft, creator, alice, MAX - 10, _seg(1000, MAX / 1000), uint64(block.timestamp), true, bytes32(0));
        _fundMock(donor, 10);
        _authorise(donor, enft);
        _topUp(enft, donor, id, 10);
        assertEq(_endow(enft, id), MAX, "endowment at max");
        assertEq(_bal(mock, address(enft)), MAX);

        // the mock's total supply is now full: a further mint silently mints zero ...
        _fundMock(donor, 5);
        assertEq(_bal(mock, donor), 0, "minted past full supply");
        // ... so a further top-up moves zero instead of wrapping the endowment to 4
        _topUp(enft, donor, id, 5);
        assertEq(_endow(enft, id), MAX, "endowment wrapped");
        // and a new deposit is credited zero
        uint256 b = _mint(enft, creator, bob, 1, _seg(1000, 1), uint64(block.timestamp), false, bytes32(0));
        assertEq(_endow(enft, b), 0);

        vm.warp(block.timestamp + 500);
        enft.accrue(id);
        uint64 half = 500 * (MAX / 1000);
        assertEq(_dist(enft, id), half);
        assertEq(_endow(enft, id), MAX - half);
        vm.warp(block.timestamp + 500);
        enft.accrue(id); // schedule over: sweep adds the remainder to the distribution
        assertEq(_dist(enft, id), MAX, "distribution wrapped");
        assertEq(_endow(enft, id), 0);

        vm.prank(alice);
        enft.claim(id);
        assertEq(_bal(mock, alice), MAX);
        assertEq(_bal(mock, address(enft)), 0);
    }

    /// cWETH cannot reach the silent-zero state: wrapping past type(uint64).max units reverts.
    function test_C2_6_cwethWrapPastUint64Max_reverts() public {
        uint256 full = uint256(MAX) * WEI_PER_UNIT;
        vm.deal(alice, full + WEI_PER_UNIT);
        vm.startPrank(alice);
        weth.deposit{value: full + WEI_PER_UNIT}();
        weth.approve(address(cweth), full + WEI_PER_UNIT);
        cweth.wrap(alice, full);
        vm.expectRevert(ERC7984ERC20Wrapper.ERC7984TotalSupplyOverflow.selector);
        cweth.wrap(alice, WEI_PER_UNIT);
        vm.stopPrank();
        assertEq(_bal(cweth, alice), MAX);
    }
}

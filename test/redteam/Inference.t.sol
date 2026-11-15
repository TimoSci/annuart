// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {externalEuint64} from "encrypted-types/EncryptedTypes.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {RedTeamBase} from "./RedTeamBase.sol";
import {EndowmentNFT} from "../../src/EndowmentNFT.sol";
import {AutoPayoutEndowmentNFT} from "../../src/AutoPayoutEndowmentNFT.sol";
import {Schedule, Segment, INDEFINITE} from "../../src/libraries/Schedule.sol";

/// @dev Task 6 of the red team: what public chain data gives away (C3-3), whether any
///      confidential amount is on the wire in cleartext (C3-6), and abuse that needs no
///      contract bug (C4-7).
///
///      C3-3. The predictor below (`_upper`, `_isAfterEnd`, and the PayoutPaid reader) uses ONLY
///      public data: the public views `scheduleOf`, `scheduleStartOf`, `scheduleEndOf`,
///      `settledOf`, `autoPayoutOf`, the block timestamp of each observed call, and event logs
///      (`ConfidentialTransfer` to see that a claim happened, `PayoutPaid` for its amount). It never calls
///      `decrypt`. The decrypted truth is read afterwards, from the claimant's balance, and only
///      to be compared with the prediction.
contract InferenceTest is RedTeamBase {
    bytes32 internal constant CONF_TRANSFER_SIG = keccak256("ConfidentialTransfer(address,address,bytes32)");
    bytes32 internal constant PAYOUT_PAID_SIG = keccak256("PayoutPaid(uint256,bytes32,uint256,uint256,bool)");

    /// @dev A whole scripted history runs inside one Foundry transaction, so the mock's handle-depth cap would trip on a
    ///      long chain that no real transaction sequence produces. Lifted for this suite (per-call limits are C5-3).
    function setUp() public override {
        super.setUp();
        disableHCUDepthLimit();
    }

    // ---- tally of the C3-3 scenarios, printed at the end of the summary test ----
    uint256 internal nExact;
    uint256 internal nBounded;
    uint256 internal nHidden;

    // =====================================================================
    // the public-data predictor
    // =====================================================================

    /// @dev Upper bound of what can have accrued in [since, until_]: the schedule integral. Public data only.
    function _upper(EndowmentNFT nft, uint256 id, uint64 since, uint64 until_) internal view returns (uint64) {
        return Schedule.integrate(nft.scheduleOf(id), nft.scheduleStartOf(id), since, until_);
    }

    /// @dev True when `until_` is at or after a fixed schedule's end, so the leftover is swept in.
    function _isAfterEnd(EndowmentNFT nft, uint256 id, uint64 until_) internal view returns (bool) {
        return until_ >= nft.scheduleEndOf(id);
    }

    enum Verdict {
        Exact, // prediction == truth
        Bounded, // truth in [0, prediction], strictly below it: the endowment had run out
        Hidden // truth above the prediction by an amount the public data cannot give (end-of-schedule leftover)
    }

    /// @dev Observes `who` claiming `id` on `nft` (a manual claim), predicts it from public data, then
    ///      compares with the decrypted truth. `since` is the time the distribution was last zeroed.
    function _observeClaim(EndowmentNFT nft, uint256 id, address who, uint64 since, string memory label)
        internal
        returns (uint64 truth, Verdict v, uint64 predicted)
    {
        IERC7984 tok = nft.token();
        uint64 before_ = _bal(tok, who);
        getRecordedLogs(); // flush
        vm.prank(who);
        nft.claim(id);
        Vm.Log[] memory logs = getRecordedLogs();

        // Public observation: a ConfidentialTransfer from the NFT contract to `who` means a claim happened.
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(tok) && logs[i].topics[0] == CONF_TRANSFER_SIG
                    && logs[i].topics[1] == bytes32(uint256(uint160(address(nft))))
                    && logs[i].topics[2] == bytes32(uint256(uint160(who)))
            ) seen = true;
        }
        assertTrue(seen, "claim must be visible as a ConfidentialTransfer from the NFT");

        uint64 nowTs = uint64(block.timestamp);
        predicted = _upper(nft, id, since, nowTs); // PUBLIC DATA ONLY
        bool afterEnd = _isAfterEnd(nft, id, nowTs);

        truth = _bal(tok, who) - before_; // oracle, used only to score the prediction
        if (afterEnd && truth != predicted) v = Verdict.Hidden;
        else if (truth == predicted) v = Verdict.Exact;
        else v = Verdict.Bounded;

        console.log(label);
        console.log("  predicted from public data:", predicted);
        console.log("  truth (decrypted)         :", truth);
        console.log("  verdict (0 exact, 1 bounded, 2 hidden):", uint256(v));
        // soundness: before the end the public bound is never below the truth
        if (!afterEnd) assertLe(truth, predicted, "public upper bound must hold before the end");
        if (v == Verdict.Exact) nExact++;
        else if (v == Verdict.Bounded) nBounded++;
        else nHidden++;
    }

    // =====================================================================
    // C3-3 scenario 1: manual claims, transfer, top-ups, endowment runs dry, fixed schedule ends
    // =====================================================================

    /// @dev Schedule: 300 s at 1/s, then 800 s at 2/s. Funded with 600; a donor adds 70 at +280 and 55 at +540.
    ///      Cumulative accrual C(t) = t (t <= 300), 300 + 2(t - 300) after. Total deposited before +540: 670.
    function test_C3_3_manualClaims_scriptedHistory_predictedFromPublicData() public {
        Segment[] memory s = new Segment[](2);
        s[0] = Segment({duration: 300, ratePerSec: 1});
        s[1] = Segment({duration: 800, ratePerSec: 2});

        _fundMock(creator, 600);
        _authorise(creator, enft);
        uint256 id = _mint(enft, creator, alice, 600, s, uint64(block.timestamp), true, bytes32(0));
        _fundMock(donor, 125);
        _authorise(donor, enft);

        uint64 since = enft.scheduleStartOf(id); // public: the distribution starts at zero at the start
        uint64 t0 = uint64(block.timestamp);
        uint64 truth;
        Verdict v;
        uint64 pred;

        vm.warp(t0 + 100);
        enft.accrue(id); // anybody; changes lastAccrualAtOf, not what a claim will pay
        assertEq(enft.lastAccrualAtOf(id), t0 + 100);

        vm.warp(t0 + 150);
        (truth, v,) = _observeClaim(enft, id, alice, since, "A1 claim at +150 (after an accrue at +100)");
        assertEq(truth, 150);
        assertTrue(v == Verdict.Exact);
        since = uint64(block.timestamp);

        vm.warp(t0 + 200);
        vm.prank(alice);
        enft.transferFrom(alice, bob, id); // accrues 50 into the distribution, which goes to bob

        vm.warp(t0 + 280);
        _topUp(enft, donor, id, 70); // hidden amount; topUp does not accrue

        vm.warp(t0 + 340);
        (truth, v,) = _observeClaim(enft, id, bob, since, "A2 claim at +340 (incl. transfer accrual, top-up hidden)");
        assertEq(truth, 230);
        assertTrue(v == Verdict.Exact);
        since = uint64(block.timestamp);

        vm.warp(t0 + 420);
        (truth, v,) = _observeClaim(enft, id, bob, since, "A3 claim at +420");
        assertEq(truth, 160);
        assertTrue(v == Verdict.Exact);
        since = uint64(block.timestamp);

        // The donation kept the endowment alive past the point (+450) where 600 alone would have run dry.
        vm.warp(t0 + 470);
        (truth, v,) = _observeClaim(enft, id, bob, since, "A4 claim at +470 (alive only because of the 70 donation)");
        assertEq(truth, 100);
        assertTrue(v == Verdict.Exact);
        since = uint64(block.timestamp);

        // Cumulative accrual would be 700 against 670 deposited: this claim is short.
        vm.warp(t0 + 500);
        (truth, v, pred) = _observeClaim(enft, id, bob, since, "A5 claim at +500 (endowment runs dry)");
        assertEq(pred, 60);
        assertEq(truth, 30);
        assertTrue(v == Verdict.Bounded);
        since = uint64(block.timestamp);

        vm.warp(t0 + 520);
        (truth, v, pred) = _observeClaim(enft, id, bob, since, "A6 claim at +520 (dry)");
        assertEq(pred, 40);
        assertEq(truth, 0);
        assertTrue(v == Verdict.Bounded);
        since = uint64(block.timestamp);

        vm.warp(t0 + 540);
        _topUp(enft, donor, id, 55); // donation after it ran dry
        vm.warp(t0 + 560);
        (truth, v, pred) = _observeClaim(enft, id, bob, since, "A7 claim at +560 (only the 55 donation is available)");
        assertEq(pred, 80);
        assertEq(truth, 55);
        assertTrue(v == Verdict.Bounded);
        since = uint64(block.timestamp);

        vm.warp(t0 + 600);
        (truth, v, pred) = _observeClaim(enft, id, bob, since, "A8 claim at +600 (dry again)");
        assertEq(pred, 80);
        assertEq(truth, 0);
        assertTrue(v == Verdict.Bounded);

        // The remaining endowment itself is never in the prediction: it stays hidden.
        assertFalse(_persistAllowed(enft.endowmentHandle(id), bob), "remaining endowment not readable by the owner");
        assertFalse(_publicDecryptable(enft.endowmentHandle(id)), "remaining endowment not public");
        // Tally for this history: A1-A4 exact, A5-A8 bounded (truth strictly below the public bound).
        assertEq(nExact, 4);
        assertEq(nBounded, 4);
        assertEq(nHidden, 0);
    }

    /// @dev A fixed schedule ends: the leftover is released with the next claim. The public bound gives only the last
    ///      accrual; the leftover is hidden. After settlement, further claims are exactly zero (settledOf is public).
    function test_C3_3_scheduleEnds_leftoverHidden_thenZeroExact() public {
        _fundMock(creator, 500);
        _authorise(creator, enft);
        uint256 id = _mint(enft, creator, alice, 500, _seg(100, 1), uint64(block.timestamp), false, bytes32(0));
        uint64 t0 = uint64(block.timestamp);
        uint64 since = t0;
        uint64 truth;
        Verdict v;
        uint64 pred;

        vm.warp(t0 + 50);
        (truth, v,) = _observeClaim(enft, id, alice, since, "B1 claim at +50");
        assertEq(truth, 50);
        assertTrue(v == Verdict.Exact);
        since = uint64(block.timestamp);

        vm.warp(t0 + 200); // schedule ended at +100
        assertFalse(enft.settledOf(id), "nobody has accrued since the end yet");
        (truth, v, pred) = _observeClaim(enft, id, alice, since, "B2 claim after the end (leftover swept in)");
        assertEq(pred, 50, "public data gives only the accrual up to the end");
        assertEq(truth, 450, "50 accrued + 400 leftover released");
        assertTrue(v == Verdict.Hidden);
        assertTrue(enft.settledOf(id));
        since = uint64(block.timestamp);

        vm.warp(t0 + 300);
        (truth, v, pred) = _observeClaim(enft, id, alice, since, "B3 claim after settlement");
        assertEq(pred, 0);
        assertEq(truth, 0);
        assertTrue(v == Verdict.Exact);
        // Tally: B1 and B3 exact, B2 hidden.
        assertEq(nExact, 2);
        assertEq(nBounded, 0);
        assertEq(nHidden, 1);
    }

    // =====================================================================
    // C3-3 scenario 2: automatic payouts. The amounts are cleartext; hindsight inference.
    // =====================================================================

    /// @dev Reads the amount of the PayoutPaid event in `logs` (public, cleartext), in token units.
    function _paidUnits(Vm.Log[] memory logs) internal view returns (uint64 units, bool found) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(apnft) && logs[i].topics[0] == PAYOUT_PAID_SIG) {
                (uint256 amountWei,,) = abi.decode(logs[i].data, (uint256, uint256, bool));
                return (uint64(amountWei / apnft.rate()), true);
            }
        }
    }

    function _autoPayout(uint256 id, uint64 since, string memory label) internal returns (uint64 publicUnits, uint64 pred) {
        uint64 nowTs = uint64(block.timestamp);
        pred = _upper(apnft, id, since, nowTs); // public prediction, before the payout
        _requestPayout(id, keeper);
        (bytes32 rid,,,) = apnft.pendingPayoutOf(id);
        assertTrue(_publicDecryptable(rid), "the unwrap amount is public by design");
        (uint64 clear, bytes memory proof) = _decryptionProof(rid);
        getRecordedLogs(); // flush
        vm.prank(keeper);
        apnft.finalizePayout(id, clear, proof);
        bool found;
        (publicUnits, found) = _paidUnits(getRecordedLogs());
        assertTrue(found);
        assertEq(publicUnits, clear, "the public event amount is the decrypted truth");
        console.log(label);
        console.log("  predicted from schedule:", pred);
        console.log("  public PayoutPaid amount:", publicUnits);
    }

    function test_C3_3_autoPayouts_scriptedHistory_exhaustionAndDonationBecomePublic() public {
        // 9000 units, 1/s for 12000 s, hourly payouts, top-ups on, no fee.
        _fundCweth(creator, 9000);
        _authorise(creator, apnft);
        uint256 id = _mintAuto(creator, alice, 9000, _seg(12000, 1), uint64(block.timestamp), true, bytes32(0), true, 1 hours, 0);
        uint64 t0 = uint64(block.timestamp);
        uint64 since = t0;
        uint64 got;
        uint64 pred;

        vm.warp(t0 + 3600);
        (got, pred) = _autoPayout(id, since, "P1 at +3600");
        assertEq(pred, 3600);
        assertEq(got, 3600); // exact from the schedule alone, remaining (5400) still hidden
        nExact++;
        since = uint64(block.timestamp);
        uint64 sumPaid = got;

        vm.warp(t0 + 7200);
        (got, pred) = _autoPayout(id, since, "P2 at +7200");
        assertEq(got, 3600);
        assertEq(got, pred);
        nExact++;
        since = uint64(block.timestamp);
        sumPaid += got;

        // 1800 left against 3600 owed: the first short payout. It is public, so the public learns the endowment ran out.
        vm.warp(t0 + 10800);
        (got, pred) = _autoPayout(id, since, "P3 at +10800 (short)");
        assertEq(pred, 3600);
        assertEq(got, 1800);
        assertLt(got, pred, "a short payout is the public signal of exhaustion");
        nBounded++; // bounded [0, 3600] in advance, exact once paid
        since = uint64(block.timestamp);
        sumPaid += got;
        // Hindsight, from public data alone: everything the token ever held up to now.
        assertEq(sumPaid, 9000, "sum of public payouts through the first short one = the secret original endowment");
        nHidden++; // the original endowment: hidden until this payout, public afterwards

        vm.warp(t0 + 11000);
        _fundCweth(donor, 250);
        _authorise(donor, apnft);
        _topUp(apnft, donor, id, 250); // donor's amount, hidden for now

        // Past the end of the schedule (12000): the donation is swept in and paid, so it becomes public.
        vm.warp(t0 + 14400);
        (got, pred) = _autoPayout(id, since, "P4 at +14400 (after the end)");
        assertEq(pred, 1200, "public bound: the accrual between the last payout and the end");
        assertEq(got, 250, "the donation, now public");
        // Since the observer knows the remaining was 0 after P3 and nothing accrues after the end beyond the
        // swept remainder, the donated amount is exactly this payout.
        nHidden++; // the donation amount: hidden until paid, public afterwards
        vm.warp(t0 + 18000); // past the interval; the last request (14400) is after the end (12000)
        vm.prank(keeper);
        vm.expectRevert(AutoPayoutEndowmentNFT.NothingLeft.selector);
        apnft.requestPayout(id, 0);
        // Tally: P1, P2 exact from the schedule; P3 bounded in advance (then public); the original endowment and the
        // donation were hidden until paid, then public.
        assertEq(nExact, 2);
        assertEq(nBounded, 1);
        assertEq(nHidden, 2);
    }

    // =====================================================================
    // C3-6: plaintext on the wire
    // =====================================================================

    /// @dev True when the 8-byte big-endian encoding of `needle` occurs at any byte offset of `hay`.
    function _has(bytes memory hay, uint64 needle) internal pure returns (bool) {
        if (hay.length < 8) return false;
        bytes8 n = bytes8(needle);
        for (uint256 i = 0; i + 8 <= hay.length; i++) {
            bytes32 w;
            assembly {
                w := mload(add(add(hay, 32), i))
            }
            if (bytes8(w) == n) return true;
        }
        return false;
    }

    /// @dev Number of places in `logs` (each topic, each data blob) where `needle` occurs.
    function _hitsInLogs(Vm.Log[] memory logs, uint64 needle) internal pure returns (uint256 hits) {
        for (uint256 i = 0; i < logs.length; i++) {
            for (uint256 j = 0; j < logs[i].topics.length; j++) {
                if (_has(abi.encodePacked(logs[i].topics[j]), needle)) hits++;
            }
            if (_has(logs[i].data, needle)) hits++;
        }
    }

    /// @dev Sends `data` to `target` as `from`, returns the logs it produced, its return data and a flag for
    ///      "needle in calldata".
    function _wire(address target, address from, bytes memory data)
        internal
        returns (Vm.Log[] memory logs, bytes memory ret)
    {
        getRecordedLogs(); // flush
        vm.prank(from);
        (bool ok, bytes memory r) = target.call(data);
        require(ok, "wire call failed");
        ret = r;
        logs = getRecordedLogs();
    }

    function _sumHits(Vm.Log[][] memory all, bytes[] memory rets, bytes[] memory calldatas, uint64 needle)
        internal
        pure
        returns (uint256 logHits, uint256 retHits, uint256 inputHits)
    {
        for (uint256 i = 0; i < all.length; i++) {
            logHits += _hitsInLogs(all[i], needle);
            if (_has(rets[i], needle)) retHits++;
            if (_has(calldatas[i], needle)) inputHits++;
        }
    }

    uint64 internal constant W_MINT = 7_777_000_111;
    uint64 internal constant W_TOPUP = 3_333_000_222;
    uint64 internal constant W_XFER = 5_550_001_234;
    uint64 internal constant W_RATE = 1_000_003;

    Vm.Log[][] internal _wl;
    bytes[] internal _wr;
    bytes[] internal _wi;

    function _record(address target, address from, bytes memory data) internal {
        (Vm.Log[] memory logs, bytes memory ret) = _wire(target, from, data);
        _wl.push();
        for (uint256 i = 0; i < logs.length; i++) {
            _wl[_wl.length - 1].push(logs[i]);
        }
        _wr.push(ret);
        _wi.push(data);
    }

    function _assertAbsent(uint64 needle, string memory label) internal view {
        uint256 l;
        uint256 r;
        uint256 c;
        for (uint256 i = 0; i < _wl.length; i++) {
            l += _hitsInLogs(_wl[i], needle);
            if (_has(_wr[i], needle)) r++;
            if (_has(_wi[i], needle)) c++;
        }
        console.log(label, "- hits in logs / returns / calldata:");
        console.log("  ", l, r, c);
        assertEq(l + r + c, 0, label);
    }

    function test_C3_6_confidentialAmountsNeverOnTheWire() public {
        _fundMock(creator, W_MINT + 42_424_242);
        _authorise(creator, enft);
        _fundMock(donor, W_TOPUP + 11_111_111);
        _authorise(donor, enft);
        _fundMock(alice, W_XFER + 99_999_999);
        uint64 t0 = uint64(block.timestamp);

        // 1. mint
        {
            (externalEuint64 h, bytes memory p) = _enc(W_MINT, creator, address(enft));
            _record(
                address(enft),
                creator,
                abi.encodeCall(enft.mint, (alice, h, p, _forever(W_RATE), t0, true, bytes32("Wire")))
            );
        }
        // 2. accrue at +40 (a public increment 40*rate appears as the accrual's scalar: expected, see C3-3)
        vm.warp(t0 + 40);
        _record(address(enft), keeper, abi.encodeCall(enft.accrue, (1)));
        // 3. claim at +91: pays 91*rate, a SUM of two accruals, so never a single scalar
        vm.warp(t0 + 91);
        _record(address(enft), alice, abi.encodeCall(enft.claim, (1)));
        // 4. top up
        vm.warp(t0 + 100);
        {
            (externalEuint64 h, bytes memory p) = _enc(W_TOPUP, donor, address(enft));
            _record(address(enft), donor, abi.encodeCall(enft.topUp, (1, h, p)));
        }
        // 5. a plain confidential token transfer with a distinctive amount
        {
            (externalEuint64 h, bytes memory p) = _enc(W_XFER, alice, address(mock));
            _record(
                address(mock),
                alice,
                abi.encodeWithSignature("confidentialTransfer(address,bytes32,bytes)", bob, h, p)
            );
        }
        // 6. an ENFT transfer
        vm.warp(t0 + 130);
        _record(address(enft), alice, abi.encodeCall(enft.transferFrom, (alice, bob, 1)));

        _assertAbsent(W_MINT, "endowment at mint must not appear");
        _assertAbsent(W_TOPUP, "top-up amount must not appear");
        _assertAbsent(91 * W_RATE, "claim amount must not appear");
        _assertAbsent(W_XFER, "token transfer amount must not appear");
        _assertAbsent(W_MINT + W_TOPUP - 130 * W_RATE, "remaining endowment must not appear");

        // Control: the searcher does see cleartext that is on the wire. The accrual increment is the plaintext
        // scalar of a trivial encryption inside the executor's event. It is public-derivable (C3-3).
        uint256 l;
        for (uint256 i = 0; i < _wl.length; i++) {
            l += _hitsInLogs(_wl[i], 40 * W_RATE);
        }
        console.log("accrual increment 40*rate (expected public), log hits:", l);
        assertGt(l, 0, "control: a public accrual increment is visible in an executor event");
    }

    /// @dev The flip side of C3-3 on the wire: a claim that pays exactly one accrual has its amount in cleartext in the
    ///      executor's trivial-encryption event, because the accrual's `owed` is a plaintext scalar. That value is the public
    ///      upper bound, not the truth: when the endowment is short, the event still shows the bound.
    function test_C3_6_singleAccrualClaim_amountVisibleAsPublicAccrualScalar() public {
        _fundMock(creator, 1000);
        _authorise(creator, enft);
        uint256 id = _mint(enft, creator, alice, 1000, _seg(10_000, 3), uint64(block.timestamp), false, bytes32(0));
        uint64 t0 = uint64(block.timestamp);
        vm.warp(t0 + 100); // 300 owed; claim is the only accrual
        _record(address(enft), alice, abi.encodeCall(enft.claim, (id)));
        uint256 l;
        for (uint256 i = 0; i < _wl.length; i++) {
            l += _hitsInLogs(_wl[i], 300);
        }
        assertGt(l, 0, "the claim amount (= one accrual) is a cleartext scalar in an executor event");
        assertEq(_bal(mock, alice), 300);

        // Capped case: 700 left, 800 owed; the event shows 800 (the bound), the truth is 700.
        vm.warp(t0 + 100 + 400);
        delete _wl;
        delete _wr;
        delete _wi;
        _record(address(enft), alice, abi.encodeCall(enft.claim, (id)));
        uint256 shownBound;
        uint256 shownTruth;
        for (uint256 i = 0; i < _wl.length; i++) {
            shownBound += _hitsInLogs(_wl[i], 1200); // 400 s x 3
            shownTruth += _hitsInLogs(_wl[i], 700);
        }
        assertGt(shownBound, 0, "the bound 1200 is in the log");
        assertEq(shownTruth, 0, "the truth (700, capped) is not");
        assertEq(_bal(mock, alice), 300 + 700);
    }

    /// @dev Positive controls: the places the brief says cleartext legitimately appears must be found by the same searcher.
    function test_C3_6_controls_wrapMockMintAndPayoutAreCleartext() public {
        // wrap: the WETH amount in wei is cleartext (Deposit event)
        uint64 wrapUnits = 3_141_592;
        uint256 wrapWei = uint256(wrapUnits) * WEI_PER_UNIT;
        vm.deal(alice, wrapWei);
        vm.startPrank(alice);
        weth.deposit{value: wrapWei}();
        weth.approve(address(cweth), wrapWei);
        vm.stopPrank();
        getRecordedLogs();
        vm.prank(alice);
        cweth.wrap(alice, wrapWei);
        assertGt(_hitsInLogs(getRecordedLogs(), uint64(wrapWei)), 0, "wrap: the wei amount is cleartext");

        // mock mint: the amount is a trivial-encrypt plaintext
        uint64 minted = 2_718_281_828;
        getRecordedLogs();
        mock.mint(bob, minted);
        assertGt(_hitsInLogs(getRecordedLogs(), minted), 0, "mock mint: the amount is cleartext");

        // automatic payout: PayoutPaid carries the amount in wei, and the decryption request is public
        uint256 id = _mintAutoSimple(alice, 5_000_555, true, 1 hours, 0);
        uint64 t0 = uint64(block.timestamp);
        vm.warp(t0 + 1000); // the 1000 s schedule has just ended: the leftover is swept in too
        _requestPayout(id, keeper);
        (bytes32 rid,,,) = apnft.pendingPayoutOf(id);
        (uint64 clear, bytes memory proof) = _decryptionProof(rid);
        getRecordedLogs();
        vm.prank(keeper);
        apnft.finalizePayout(id, clear, proof);
        Vm.Log[] memory logs = getRecordedLogs();
        assertEq(clear, 5_000_555, "the schedule has ended, so the whole endowment is paid");
        assertGt(_hitsInLogs(logs, uint64(uint256(clear) * WEI_PER_UNIT)), 0, "payout: amountWei is cleartext");
    }

    // =====================================================================
    // C4-7: abuse without a bug
    // =====================================================================

    // ---- (1) unfunded ENFT presented as funded ----

    /// @dev A creator with 1 unit mints a token "backed by" 1,000,000 units. The mint succeeds, emits the same public
    ///      data as a funded token, and the buyer has no way to check it. Cross-reference: D-C2-2.
    function test_C4_7_unfundedMint_lookedIdenticalToFundedOnPublicData() public {
        // honest, funded
        _fundMock(creator, 1_000_000);
        _authorise(creator, enft);
        uint256 funded = _mint(enft, creator, alice, 1_000_000, _seg(1000, 1000), uint64(block.timestamp), false, bytes32("Pension"));

        // fraudulent: the creator holds 1 unit and "mints" 1,000,000
        address fraud = makeAddr("fraud");
        _fundMock(fraud, 1);
        _authorise(fraud, enft);
        getRecordedLogs();
        uint256 empty = _mint(enft, fraud, bob, 1_000_000, _seg(1000, 1000), uint64(block.timestamp), false, bytes32("Pension"));
        Vm.Log[] memory logs = getRecordedLogs();

        // The mint succeeded, a ConfidentialTransfer event (of an encrypted amount) was emitted for it, and every public
        // view matches the funded token's.
        bool sawTransfer;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(mock) && logs[i].topics[0] == CONF_TRANSFER_SIG) sawTransfer = true;
        }
        assertTrue(sawTransfer, "a transfer event is emitted even though nothing moved");
        assertEq(enft.nameOf(empty), enft.nameOf(funded));
        assertEq(enft.scheduleEndOf(empty), enft.scheduleEndOf(funded));
        assertEq(enft.topUpsAllowedOf(empty), enft.topUpsAllowedOf(funded));
        assertEq(enft.scheduleOf(empty).length, enft.scheduleOf(funded).length);
        assertEq(enft.scheduleOf(empty)[0].ratePerSec, enft.scheduleOf(funded)[0].ratePerSec);

        // Neither owner (nor anyone) can read the endowment to check.
        assertFalse(_persistAllowed(enft.endowmentHandle(empty), bob), "the buyer cannot read the endowment");
        assertFalse(_persistAllowed(enft.endowmentHandle(empty), fraud), "not even the creator can re-read it");

        // The only difference is the truth: the funded token pays, the other pays nothing.
        vm.warp(block.timestamp + 500);
        vm.prank(alice);
        enft.claim(funded);
        vm.prank(bob);
        enft.claim(empty);
        assertEq(_bal(mock, alice), 500_000, "the funded token paid 500 s x 1000");
        assertEq(_bal(mock, bob), 0, "the unfunded token paid nothing");
        // After the end it still pays nothing: there is no leftover to release.
        vm.warp(block.timestamp + 1000);
        vm.prank(bob);
        enft.claim(empty);
        assertEq(_bal(mock, bob), 0);
    }

    // ---- (2) look-alike names ----

    function test_C4_7_lookAlikeNames_accepted() public {
        _fundMock(creator, 10);
        _authorise(creator, enft);
        _fundMock(mallory, 10);
        _authorise(mallory, enft);
        uint256 real = _mint(enft, creator, alice, 5, _seg(1000, 1), uint64(block.timestamp), false, bytes32("Gold Pension"));
        // exact duplicate, same name
        uint256 dup = _mint(enft, mallory, alice, 1, _seg(1000, 1), uint64(block.timestamp), false, bytes32("Gold Pension"));
        // capital I for lower-case l, zero for O
        uint256 lookalike = _mint(enft, mallory, alice, 1, _seg(1000, 1), uint64(block.timestamp), false, bytes32("G0Id Pension"));
        assertEq(enft.nameOf(real), enft.nameOf(dup), "names are not unique");
        assertTrue(enft.nameOf(lookalike) != enft.nameOf(real));
        assertTrue(real != dup && dup != lookalike);
        // The creator differs, and that is the only unforgeable difference
        // (the web app shows it as the creator frame and tooltip).
        assertEq(enft.ownerOf(dup), alice);
    }

    // ---- (3) unsolicited ENFTs ----

    function test_C4_7_unsolicitedEnft_landsWithoutConsent() public {
        _fundMock(mallory, 1);
        _authorise(mallory, enft);
        // A name that reads like an instruction. The charset allows letters, digits, space and - _ . '.
        bytes32 bait = bytes32("Visit evil.com to claim");
        uint256 id = _mint(enft, mallory, alice, 1, _seg(1000, 1), uint64(block.timestamp), false, bait);
        assertEq(enft.ownerOf(id), alice, "alice owns it without having agreed");
        assertEq(enft.nameOf(id), bait);
        // She cannot refuse: no accept hook on an EOA. She can only transfer it away.
        vm.prank(alice);
        enft.transferFrom(alice, address(0xdead), id);
        assertEq(enft.ownerOf(id), address(0xdead));
    }

    // ---- (4) seller front-run: claim just before a sale ----

    /// @dev The buyer pays for a token that "has" 500 claimable (a figure only the owner can see, so only the
    ///      seller can show it). Just before the transfer the seller claims it all. The buyer receives a token whose
    ///      claimable balance is zero.
    function test_C4_7_sellerFrontRun_claimBeforeSale_buyerGetsEmptyDistribution() public {
        uint256 id = _mintSimple(alice, 2000, false); // 1/s for 1000 s
        vm.warp(block.timestamp + 500); // 500 accrued, and nobody has accrued it yet
        // Front-run: claim, then sell
        vm.prank(alice);
        enft.claim(id);
        vm.prank(alice);
        enft.transferFrom(alice, bob, id); // the "sale"
        assertEq(_dist(enft, id), 0, "the buyer's distribution is zero");
        vm.prank(bob);
        enft.claim(id);
        assertEq(_bal(mock, alice), 500, "the seller took the 500");
        assertEq(_bal(mock, bob), 0, "the buyer got nothing for the accrued part");
        // What remains for the buyer is only the future accrual, which the schedule makes public.
        assertEq(_upper(enft, id, uint64(block.timestamp), enft.scheduleEndOf(id)), 500);
    }

    /// @dev Control for the front-run: without it the buyer receives the 500 accrued before the sale.
    function test_C4_7_sellerFrontRun_control_noFrontRun_buyerGetsAccrual() public {
        uint256 id = _mintSimple(alice, 2000, false);
        vm.warp(block.timestamp + 500);
        vm.prank(alice);
        enft.transferFrom(alice, bob, id);
        vm.prank(bob);
        enft.claim(id);
        assertEq(_bal(mock, bob), 500, "the buyer gets 500 when the seller does not front-run");
        assertEq(_bal(mock, alice), 0);
    }

    /// @dev The same with automatic payouts: the seller requests a payout just before the sale. The payout recipient
    ///      is fixed at request time, so finalising after the sale still pays the SELLER, and the buyer's
    ///      distribution is zero.
    function test_C4_7_sellerFrontRun_requestPayoutBeforeSale_paysSellerAfterSale() public {
        uint256 id = _mintAutoSimple(alice, 1000, true, 1 hours, 0); // 1000 s at 1/s
        vm.warp(block.timestamp + 1000);
        bytes32 rid = _requestPayout(id, alice); // the seller requests (anyone could)
        vm.prank(alice);
        apnft.transferFrom(alice, bob, id); // the sale

        (, address recipient,,) = apnft.pendingPayoutOf(id);
        assertEq(recipient, alice, "recipient was fixed at request time");
        (bool enabled,,,) = apnft.autoPayoutOf(id);
        assertFalse(enabled, "the new owner does not inherit payouts");
        assertEq(_dist(apnft, id), 0, "the buyer's distribution is zero");

        // The transfer switched payouts off for the buyer
        vm.prank(bob);
        vm.expectRevert(AutoPayoutEndowmentNFT.AutoPayoutDisabled.selector);
        apnft.requestPayout(id, 0);

        uint256 aliceEthBefore = alice.balance;
        (uint64 clear, bytes memory proof) = _decryptionProof(rid);
        vm.prank(keeper);
        apnft.finalizePayout(id, clear, proof);
        assertEq(clear, 1000);
        assertEq(alice.balance - aliceEthBefore, uint256(clear) * WEI_PER_UNIT, "the seller is paid the whole accrued amount in ETH");
        assertEq(bob.balance, 0, "the buyer gets nothing");
    }

    // ---- (5) approval phished from an owner ----

    /// @dev An ERC-721 approval lets the approved address take the token WITH its unclaimed balance, and an approved
    ///      operator cannot claim itself (claim is owner-only) but can transfer to itself and then claim.
    function test_C4_7_phishedErc721Approval_takesTokenAndAccrual() public {
        uint256 id = _mintSimple(alice, 2000, false);
        vm.warp(block.timestamp + 500);
        vm.prank(alice);
        enft.setApprovalForAll(mallory, true); // the phished signature
        vm.prank(mallory);
        vm.expectRevert(EndowmentNFT.NotOwner.selector);
        enft.claim(id); // cannot claim as an operator...
        vm.prank(mallory);
        enft.transferFrom(alice, mallory, id); // ...but can take the token
        vm.prank(mallory);
        enft.claim(id);
        assertEq(_bal(mock, mallory), 500, "the phisher got the unclaimed 500");
        assertEq(enft.ownerOf(id), mallory);
    }

    /// @dev The confidential-token approval: setOperator on the token for any address lets that address move the
    ///      holder's whole balance. The app's Authorise button grants this to the ENFT contract only, for a year.
    function test_C4_7_phishedTokenOperator_drainsBalance() public {
        _fundMock(alice, 12_345);
        vm.prank(alice);
        mock.setOperator(mallory, uint48(block.timestamp + 1 days));
        (externalEuint64 h, bytes memory p) = _enc(12_345, mallory, address(mock));
        vm.prank(mallory);
        mock.confidentialTransferFrom(alice, mallory, h, p);
        assertEq(_bal(mock, mallory), 12_345);
        assertEq(_bal(mock, alice), 0);
    }
}

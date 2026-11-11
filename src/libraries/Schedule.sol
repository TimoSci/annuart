// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

struct Segment {
    uint64 duration;   // seconds this segment lasts
    uint64 ratePerSec; // base units accrued per second during this segment
}

/// @dev Duration sentinel: a segment with this duration never ends.
uint64 constant INDEFINITE = type(uint64).max;

library Schedule {
    /// @dev True when `s` is non-empty and its last segment never ends.
    function isIndefinite(Segment[] memory s) internal pure returns (bool) {
        return s.length > 0 && s[s.length - 1].duration == INDEFINITE;
    }

    /// @dev Total accrued over [from, to] intersected with the schedule window,
    ///      saturating at type(uint64).max instead of overflowing.
    function integrate(Segment[] memory s, uint64 start, uint64 from, uint64 to)
        internal
        pure
        returns (uint64)
    {
        if (to <= from) return 0;
        uint256 segStart = start;
        uint256 acc = 0;
        for (uint256 i = 0; i < s.length; i++) {
            uint256 segEnd = segStart + s[i].duration;
            uint256 lo = from > segStart ? from : segStart;
            uint256 hi = to < segEnd ? to : segEnd;
            if (hi > lo) {
                acc += uint256(s[i].ratePerSec) * (hi - lo);
                if (acc >= type(uint64).max) return type(uint64).max;
            }
            segStart = segEnd;
        }
        return uint64(acc);
    }

    /// @dev start + sum of all segment durations, saturating at type(uint64).max.
    function scheduleEnd(Segment[] memory s, uint64 start) internal pure returns (uint64) {
        uint256 total = start;
        for (uint256 i = 0; i < s.length; i++) {
            total += s[i].duration;
            if (total >= type(uint64).max) return type(uint64).max;
        }
        return uint64(total);
    }
}

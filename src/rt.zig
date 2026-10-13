// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Minimal runtime for all netline programs: our own panic handler
//! and std options. Pulled in from each program's root file:
//!
//!     pub const panic = rt.panic;
//!     pub const std_options = rt.std_options;
//!
//! The default handler drags in stack printing, debug info and formatting —
//! more than half of a binary's code. Here a panic just writes the message to stderr
//! and exits the process. ReleaseSafe bounds checks stay in place.

const std = @import("std");
const sys = @import("sys.zig");

pub const std_options: std.Options = .{
    // no SIGSEGV handler and no separate 256 KB signal stack:
    // there is nothing to print a stack trace with anyway (binaries are built without debug info)
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};

pub const panic = struct {
    pub fn call(msg: []const u8, _: ?usize) noreturn {
        @branchHint(.cold);
        var buf: [256]u8 = undefined;
        const s = sys.joinZ(&buf, &.{ "netline: internal error: ", msg, "\n" });
        _ = sys.write(2, s) catch {};
        sys.exit(134);
    }
    pub fn sentinelMismatch(_: anytype, _: anytype) noreturn {
        call("sentinel mismatch", null);
    }
    pub fn unwrapError(_: anyerror) noreturn {
        call("attempt to unwrap error", null);
    }
    pub fn outOfBounds(_: usize, _: usize) noreturn {
        call("index out of bounds", null);
    }
    pub fn startGreaterThanEnd(_: usize, _: usize) noreturn {
        call("start index is larger than end index", null);
    }
    pub fn inactiveUnionField(_: anytype, _: anytype) noreturn {
        call("access of inactive union field", null);
    }
    pub fn sliceCastLenRemainder(_: usize) noreturn {
        call("slice length does not divide exactly", null);
    }
    pub fn reachedUnreachable() noreturn {
        call("reached unreachable code", null);
    }
    pub fn unwrapNull() noreturn {
        call("attempt to use null value", null);
    }
    pub fn castToNull() noreturn {
        call("cast causes pointer to be null", null);
    }
    pub fn incorrectAlignment() noreturn {
        call("incorrect alignment", null);
    }
    pub fn invalidErrorCode() noreturn {
        call("invalid error code", null);
    }
    pub fn integerOutOfBounds() noreturn {
        call("integer does not fit in destination type", null);
    }
    pub fn integerOverflow() noreturn {
        call("integer overflow", null);
    }
    pub fn shlOverflow() noreturn {
        call("left shift overflowed bits", null);
    }
    pub fn shrOverflow() noreturn {
        call("right shift overflowed bits", null);
    }
    pub fn divideByZero() noreturn {
        call("division by zero", null);
    }
    pub fn exactDivisionRemainder() noreturn {
        call("exact division produced remainder", null);
    }
    pub fn integerPartOutOfBounds() noreturn {
        call("integer part of floating point value out of bounds", null);
    }
    pub fn corruptSwitch() noreturn {
        call("switch on corrupt value", null);
    }
    pub fn shiftRhsTooBig() noreturn {
        call("shift amount is greater than the type size", null);
    }
    pub fn invalidEnumValue() noreturn {
        call("invalid enum value", null);
    }
    pub fn forLenMismatch() noreturn {
        call("for loop over objects with non-equal lengths", null);
    }
    pub fn copyLenMismatch() noreturn {
        call("source and destination have non-equal lengths", null);
    }
    pub fn memcpyAlias() noreturn {
        call("@memcpy arguments alias", null);
    }
    pub fn noreturnReturned() noreturn {
        call("'noreturn' function returned", null);
    }
};

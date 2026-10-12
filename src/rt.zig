// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Минимальная среда выполнения для всех программ zpanel: свой обработчик паники
//! и настройки std. Подключается из корневого файла каждой программы:
//!
//!     pub const panic = rt.panic;
//!     pub const std_options = rt.std_options;
//!
//! Стандартный обработчик тянет печать стека, отладочную информацию и форматирование —
//! это больше половины кода бинарника. Здесь паника просто пишет сообщение в stderr
//! и завершает процесс. Проверки границ ReleaseSafe при этом остаются на месте.

const std = @import("std");
const sys = @import("sys.zig");

pub const std_options: std.Options = .{
    // без обработчика SIGSEGV и без отдельного стека сигналов на 256 КБ:
    // стек всё равно печатать нечем (бинарники собираются без отладочной информации)
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};

pub const panic = struct {
    pub fn call(msg: []const u8, _: ?usize) noreturn {
        @branchHint(.cold);
        var buf: [256]u8 = undefined;
        const s = sys.joinZ(&buf, &.{ "zpanel: внутренняя ошибка: ", msg, "\n" });
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

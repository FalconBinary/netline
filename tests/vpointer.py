# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
"""A pointer for tests: a small Wayland client over zwlr_virtual_pointer_manager_v1, no libraries."""

import os
import socket
import struct
import time

BTN_LEFT = 0x110
BTN_RIGHT = 0x111


class Pointer:
    def __init__(self, display, width, height):
        self.width, self.height = width, height
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"], display))
        self.next_id = 2
        registry = self._id()
        self._send(1, 1, struct.pack("<I", registry))  # wl_display.get_registry
        done = self._id()
        self._send(1, 0, struct.pack("<I", done))  # wl_display.sync
        names = self._read_globals(done)
        manager = self._id()
        self._bind(registry, names["zwlr_virtual_pointer_manager_v1"], "zwlr_virtual_pointer_manager_v1", 1, manager)
        self.ptr = self._id()
        self._send(manager, 0, struct.pack("<II", 0, self.ptr))  # create_virtual_pointer(seat = default)
        self.t0 = time.monotonic()

    def _id(self):
        self.next_id += 1
        return self.next_id - 1

    def _send(self, obj, op, body=b""):
        self.s.sendall(struct.pack("<II", obj, ((8 + len(body)) << 16) | op) + body)

    def _bind(self, registry, name, iface, version, new_id):
        enc = iface.encode() + b"\0"
        enc += b"\0" * (-len(enc) % 4)
        self._send(registry, 0, struct.pack("<I", name) + struct.pack("<I", len(iface) + 1) + enc + struct.pack("<II", version, new_id))

    def _read_globals(self, done):
        names, data = {}, b""
        while True:
            data += self.s.recv(65536)
            while len(data) >= 8:
                obj, hdr = struct.unpack_from("<II", data)
                size = hdr >> 16
                if len(data) < size:
                    break
                body, data = data[8:size], data[size:]
                if obj == done:
                    return names
                if obj == 2 and (hdr & 0xffff) == 0:
                    name, n = struct.unpack_from("<II", body)
                    names[body[8:8 + n - 1].decode()] = name

    def _ms(self):
        return int((time.monotonic() - self.t0) * 1000)

    def _frame(self):
        self._send(self.ptr, 4)

    def move(self, x, y):
        self._send(self.ptr, 1, struct.pack("<IIIII", self._ms(), x, y, self.width, self.height))  # motion_absolute
        self._frame()

    def button(self, pressed, code=BTN_LEFT):
        self._send(self.ptr, 2, struct.pack("<III", self._ms(), code, 1 if pressed else 0))
        self._frame()

    def click(self, x, y, code=BTN_LEFT):
        self.move(x, y)
        time.sleep(0.08)
        self.button(True, code)
        time.sleep(0.03)
        self.button(False, code)

    def drag(self, x0, y, x1, steps=12):
        self.move(x0, y)
        time.sleep(0.06)
        self.button(True)
        for i in range(1, steps + 1):
            self.move(x0 + (x1 - x0) * i // steps, y)
            time.sleep(0.012)
        self.button(False)

    def wheel(self, notches):
        """Positive: down."""
        for _ in range(abs(notches)):
            value = 15 if notches > 0 else -15
            self._send(self.ptr, 3, struct.pack("<IIi", self._ms(), 0, value * 256))
            self._frame()
            time.sleep(0.05)

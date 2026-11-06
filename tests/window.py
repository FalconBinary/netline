# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
"""A fullscreen window for tests: one opaque color over the whole output, xdg-shell, no libraries."""

import os
import socket
import struct
import threading

XRGB8888 = 1


def _str(s):
    enc = s.encode() + b"\0"
    return struct.pack("<I", len(enc)) + enc + b"\0" * (-len(enc) % 4)


class Window:
    def __init__(self, display, rgb):
        self.rgb = rgb
        self.sizes = []  # every size the compositor asked for
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"], display))
        self.next_id = 2
        self.lock = threading.Lock()
        self.data = b""
        registry = self._id()
        self._send(1, 1, struct.pack("<I", registry))  # wl_display.get_registry
        done = self._id()
        self._send(1, 0, struct.pack("<I", done))  # wl_display.sync
        names = {}
        for obj, op, body in self._events():
            if obj == done:
                break
            if obj == registry and op == 0:
                name, n = struct.unpack_from("<II", body)
                names[body[8:8 + n - 1].decode()] = name
        self.compositor = self._bind(registry, names, "wl_compositor", 4)
        self.shm = self._bind(registry, names, "wl_shm", 1)
        self.wm = self._bind(registry, names, "xdg_wm_base", 1)
        self.surface = self._id()
        self._send(self.compositor, 0, struct.pack("<I", self.surface))  # create_surface
        self.xdg = self._id()
        self._send(self.wm, 2, struct.pack("<II", self.xdg, self.surface))  # get_xdg_surface
        self.top = self._id()
        self._send(self.xdg, 1, struct.pack("<I", self.top))  # get_toplevel
        self._send(self.top, 2, _str("fullscreen test"))  # set_title
        self._send(self.top, 11, struct.pack("<I", 0))  # set_fullscreen(any output)
        self._send(self.surface, 6)  # commit: a configure comes back
        self.w = self.h = 0
        self.buffer = None
        self.alive = True
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _id(self):
        self.next_id += 1
        return self.next_id - 1

    def _send(self, obj, op, body=b"", fds=()):
        msg = struct.pack("<II", obj, ((8 + len(body)) << 16) | op) + body
        with self.lock:
            if fds:
                socket.send_fds(self.s, [msg], list(fds))
            else:
                self.s.sendall(msg)

    def _bind(self, registry, names, iface, version):
        new = self._id()
        self._send(registry, 0, struct.pack("<I", names[iface]) + _str(iface) + struct.pack("<II", version, new))
        return new

    def _events(self):
        while True:
            while len(self.data) >= 8:
                obj, hdr = struct.unpack_from("<II", self.data)
                size = hdr >> 16
                if size < 8 or len(self.data) < size:
                    break
                body, self.data = self.data[8:size], self.data[size:]
                yield obj, hdr & 0xffff, body
            chunk = self.s.recv(65536)
            if not chunk:
                return
            self.data += chunk

    def _run(self):
        w = h = 0
        try:
            for obj, op, body in self._events():
                if obj == 1 and op == 0:  # wl_display.error
                    oid, code = struct.unpack_from("<II", body)
                    print(f"window: protocol error on {oid}, code {code}", flush=True)
                elif obj == self.wm and op == 0:  # ping
                    self._send(self.wm, 3, body[:4])  # pong
                elif obj == self.top and op == 0:  # configure(width, height, states)
                    w, h = struct.unpack_from("<ii", body)
                elif obj == self.xdg and op == 0:  # configure(serial): the size is settled
                    self._send(self.xdg, 4, body[:4])  # ack_configure
                    self.sizes.append((w, h))
                    # 0: our choice; a window not yet on screen is made fullscreen once it maps
                    size = (w if w > 0 else self.w or 640, h if h > 0 else self.h or 480)
                    if size != (self.w, self.h):
                        self._draw(*size)
                    else:
                        self._send(self.surface, 6)
        except OSError:
            pass
        self.alive = False

    def _draw(self, w, h):
        self.w, self.h = w, h
        stride = w * 4
        size = stride * h
        fd = os.memfd_create("window")
        r, g, b = self.rgb
        os.write(fd, struct.pack("<I", (r << 16) | (g << 8) | b) * (w * h))
        pool = self._id()
        self._send(self.shm, 0, struct.pack("<Ii", pool, size), fds=[fd])  # create_pool
        os.close(fd)
        buf = self._id()
        self._send(pool, 0, struct.pack("<IiiiiI", buf, 0, w, h, stride, XRGB8888))  # create_buffer
        self._send(pool, 1)  # the buffer keeps the memory
        self._send(self.surface, 1, struct.pack("<Iii", buf, 0, 0))  # attach
        self._send(self.surface, 9, struct.pack("<iiii", 0, 0, w, h))  # damage_buffer
        self._send(self.surface, 6)  # commit
        if self.buffer:
            self._send(self.buffer, 0)  # destroy the old one
        self.buffer = buf

    def close(self):
        """The window goes with its connection."""
        try:
            self.s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.thread.join(5)
        self.s.close()

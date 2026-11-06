# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
"""The part of mango's IPC the panel uses, for tests under another compositor: `watch all-tags` and
`watch all-clients`, with the lines as mango 0.18 builds them (src/ipc/ipc.c). Like mango, a change
sends the tags line to every tags watcher first, then the windows line to every windows watcher."""

import json
import os
import socket
import threading
import time


class FakeMango:
    def __init__(self, path, monitor, uid, tags=9):
        self.monitor, self.ntags = monitor, tags
        self.active = 1
        self.windows = []  # (title, fullscreen)
        self.tag_watchers, self.window_watchers = [], []
        self.lock = threading.Lock()
        if os.path.exists(path):
            os.unlink(path)
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        os.chown(path, uid, uid)
        self.srv.listen(8)
        threading.Thread(target=self._accept, daemon=True).start()

    def tags_line(self):
        tags = [{"index": i, "is_active": i == self.active, "is_urgent": False, "layout": "T",
                 "client_count": len(self.windows) if i == self.active else 0} for i in range(1, self.ntags + 1)]
        return {"all_tags": [{"monitor": self.monitor, "tags": tags}]}

    def windows_line(self):
        clients = []
        for n, (title, full) in enumerate(self.windows, 1):
            clients.append({
                "id": n, "pid": 1000 + n, "foreign_toplevel_id": f"{n:032x}", "title": title, "appid": "test",
                "monitor": self.monitor, "tags": [self.active], "is_xwayland": False, "is_swallowing": False,
                "is_swallowedby": False, "is_group": False, "is_group_focus": False, "is_visible": True,
                "is_focused": n == len(self.windows), "is_fullscreen": full, "is_floating": False,
                "is_maximized": False, "is_global": False, "is_unglobal": False, "is_overlay": False,
                "is_fakefullscreen": False, "is_minimized": False, "is_urgent": False, "is_scratchpad": False,
                "is_namedscratchpad": False, "x": 0, "y": 0, "width": 1280, "height": 720, "scroller_proportion": 0.9,
            })
        return {"clients": clients}

    @staticmethod
    def _line(obj):
        return (json.dumps(obj, separators=(",", ":"), ensure_ascii=False) + "\n").encode()

    def _accept(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _serve(self, c):
        cmd = b""
        while not cmd.endswith(b"\n"):
            chunk = c.recv(256)
            if not chunk:
                c.close()
                return
            cmd += chunk
        cmd = cmd.strip().decode()
        with self.lock:
            if cmd == "watch all-tags":
                self.tag_watchers.append(c)
                c.sendall(self._line(self.tags_line()))
            elif cmd == "watch all-clients":
                self.window_watchers.append(c)
                c.sendall(self._line(self.windows_line()))
            else:
                c.sendall(b'{"error":"unknown command"}\n')
                c.close()

    def changed(self, windows_first=False, gap=0.0):
        """Tell the watchers, in mango's order or the other way around. `gap`: seconds between the two
        lines, longer than mango takes to build the second one, so that a reader watching both wakes twice."""
        with self.lock:
            groups = [(self.tag_watchers, self._line(self.tags_line())),
                      (self.window_watchers, self._line(self.windows_line()))]
            if windows_first:
                groups.reverse()
            for k, (watchers, line) in enumerate(groups):
                if k and gap:
                    time.sleep(gap)
                for c in watchers[:]:
                    try:
                        c.sendall(line)
                    except OSError:
                        watchers.remove(c)

    def close(self):
        with self.lock:
            for c in self.tag_watchers + self.window_watchers:
                c.close()
            self.tag_watchers, self.window_watchers = [], []
        self.srv.close()

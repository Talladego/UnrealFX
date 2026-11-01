#!/usr/bin/env python3
"""UnrealFX helper (Python) - watch logs/UnrealFX.log and play WAVs.

Replaces the AutoIt tray exe so OBS Application Audio Capture can bind a real window
on this process (title: UnrealFX). Stdlib only (winsound + tkinter).
"""

from __future__ import annotations

import os
import sys
import threading
import time
import winsound

# Avoid writing bytecode under Controlled Folder Access trees.
os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
sys.dont_write_bytecode = True

VOLUME_PERCENT = 15  # matches legacy AutoIt SoundSetWaveVolume(15)
# FX is instant in-game; keep this low so WAV pickup stays close to the overlay.
POLL_SECONDS = 0.05
# tasklist is expensive (spawns a process): only re-check the WAR client on this cadence.
WAR_PROCESS_CHECK_SECONDS = 5.0
# A trailing line without a newline is played once the file has been quiet this long.
PARTIAL_LINE_FLUSH_SECONDS = 0.15
WAR_IMAGE_NAMES = ("war.exe", "war-64.exe")
WINDOW_TITLE = "UnrealFX"


def addon_dir() -> str:
    # PyInstaller onefile: data/WAVs live next to the .exe, not in _MEIPASS.
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def find_game_root(start_dir: str) -> str:
    probe = os.path.abspath(start_dir)
    for _ in range(9):
        if os.path.isfile(os.path.join(probe, "WAR.exe")) or os.path.isfile(
            os.path.join(probe, "WAR-64.exe")
        ):
            return probe
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    fallback = os.path.abspath(os.path.join(start_dir, "..", "..", ".."))
    return fallback


def war_client_pids() -> set[int]:
    """PIDs of WAR.exe / WAR-64.exe from one filtered tasklist call."""
    import subprocess

    pids: set[int] = set()
    try:
        creation = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        proc = subprocess.run(
            # Server-side filter keeps the output to the few WAR* rows.
            ["tasklist", "/FI", "IMAGENAME eq WAR*", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
            creationflags=creation,
        )
    except (OSError, subprocess.TimeoutExpired):
        return pids
    for row in (proc.stdout or "").splitlines():
        # "WAR-64.exe","1234",...
        parts = [p.strip().strip('"') for p in row.split(",")]
        if len(parts) >= 2 and parts[0].lower() in WAR_IMAGE_NAMES and parts[1].isdigit():
            pids.add(int(parts[1]))
    return pids


def war_client_running() -> bool:
    return bool(war_client_pids())


class LogTail:
    """Follow a growing text log by byte offset (only new bytes are read).

    The offset resets to 0 when the file shrinks (log recreated) and to the
    current end when following (re)starts, so old entries are never replayed.
    UTF-16 logs (BOM) are decoded incrementally; others as UTF-8.
    """

    def __init__(self, path: str) -> None:
        self.path = path
        self.offset: int | None = None
        self.decoder = None
        self.pending = ""
        self.skip_to_newline = False
        self.last_growth = 0.0

    def stop(self) -> None:
        self.offset = None

    def _size(self) -> int:
        try:
            return int(os.stat(self.path).st_size)
        except OSError:
            return -1

    def _reset(self, offset: int) -> None:
        import codecs

        encoding = "utf-8"
        bom = 0
        try:
            with open(self.path, "rb") as handle:
                head = handle.read(3)
        except OSError:
            head = b""
        if head.startswith(b"\xff\xfe"):
            encoding, bom = "utf-16-le", 2
        elif head.startswith(b"\xfe\xff"):
            encoding, bom = "utf-16-be", 2
        elif head.startswith(b"\xef\xbb\xbf"):
            bom = 3
        if offset < bom:
            offset = bom
        elif bom == 2 and (offset - bom) % 2:
            offset -= 1  # keep UTF-16 code units aligned
        self.offset = offset
        self.decoder = codecs.getincrementaldecoder(encoding)(errors="replace")
        self.pending = ""
        self.skip_to_newline = False

    def poll(self, now: float) -> list[str]:
        size = self._size()
        if size < 0:
            return []
        if self.offset is None:
            self._reset(size)  # start at the end: do not replay old entries
            self.last_growth = now
            return []
        if size < self.offset:
            self._reset(0)  # file was recreated / truncated
        lines: list[str] = []
        if size > self.offset:
            try:
                with open(self.path, "rb") as handle:
                    handle.seek(self.offset)
                    data = handle.read(size - self.offset)
            except OSError:
                return []
            self.offset += len(data)
            self.last_growth = now
            text = self.pending + self.decoder.decode(data)
            parts = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
            self.pending = parts.pop()
            if self.skip_to_newline and parts:
                parts.pop(0)  # rest of a line already played as a partial
                self.skip_to_newline = False
            lines.extend(parts)
        elif self.pending and now - self.last_growth >= PARTIAL_LINE_FLUSH_SECONDS:
            if not self.skip_to_newline:
                lines.append(self.pending)
            self.pending = ""
            self.skip_to_newline = True
        return lines


def wav_for_line(addon: str, line: str) -> str | None:
    lowered = line.lower()
    if "scenariopop" in lowered:
        name = "notify.wav"
    else:
        # Legacy AutoIt used StringMid(line, 22); also accept last token.
        keyword = line[21:].strip() if len(line) >= 22 else line.strip()
        if not keyword:
            parts = line.strip().split()
            keyword = parts[-1] if parts else ""
        keyword = "".join(ch for ch in keyword if ch.isalnum() or ch in ("_", "-"))
        if not keyword:
            return None
        name = f"{keyword}.wav"
    path = os.path.join(addon, "files", name)
    return path if os.path.isfile(path) else None


def set_wave_volume(percent: int) -> None:
    """Best-effort waveOut volume (0-100), same intent as AutoIt SoundSetWaveVolume."""
    try:
        import ctypes

        level = max(0, min(100, int(percent)))
        # waveOut volume is 0x0000-0xFFFF per channel, packed as DWORD.
        word = int(round(level / 100.0 * 0xFFFF)) & 0xFFFF
        value = (word << 16) | word
        ctypes.windll.winmm.waveOutSetVolume(0, value)
    except Exception:
        pass


def play_wav(path: str) -> None:
    try:
        winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT)
    except Exception:
        pass


def flash_game_window() -> None:
    try:
        import ctypes
        from ctypes import wintypes

        user32 = ctypes.windll.user32

        EnumWindows = user32.EnumWindows
        EnumWindowsProc = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)
        GetWindowTextW = user32.GetWindowTextW
        GetWindowTextLengthW = user32.GetWindowTextLengthW
        IsWindowVisible = user32.IsWindowVisible
        GetWindowThreadProcessId = user32.GetWindowThreadProcessId
        FlashWindowEx = user32.FlashWindowEx

        class FLASHWINFO(ctypes.Structure):
            _fields_ = [
                ("cbSize", wintypes.UINT),
                ("hwnd", wintypes.HWND),
                ("dwFlags", wintypes.DWORD),
                ("uCount", wintypes.UINT),
                ("dwTimeout", wintypes.DWORD),
            ]

        pids = war_client_pids()
        if not pids:
            return

        target: int | None = None

        def callback(hwnd: int, _lparam: int) -> bool:
            nonlocal target
            if not IsWindowVisible(hwnd):
                return True
            pid = wintypes.DWORD()
            GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if int(pid.value) not in pids:
                return True
            length = GetWindowTextLengthW(hwnd)
            if length <= 0:
                return True
            buf = ctypes.create_unicode_buffer(length + 1)
            GetWindowTextW(hwnd, buf, length + 1)
            if buf.value:
                target = int(hwnd)
                return False
            return True

        EnumWindows(EnumWindowsProc(callback), 0)
        if not target:
            return
        info = FLASHWINFO(ctypes.sizeof(FLASHWINFO), target, 0x3, 3, 0)  # FLASHW_ALL
        FlashWindowEx(ctypes.byref(info))
    except Exception:
        pass


def create_obs_window(on_ready) -> None:
    """Named window so OBS Application Audio Capture can bind this process.

    Must be a normal top-level window (not toolwindow / off-screen cloaked) or OBS
    omits it from the Application Audio Capture picker.
    """
    import tkinter as tk

    root = tk.Tk()
    root.title(WINDOW_TITLE)
    root.geometry("220x48+40+40")
    root.resizable(False, False)
    root.attributes("-topmost", False)
    try:
        icon = os.path.join(addon_dir(), "files", "squigicon.ico")
        if os.path.isfile(icon):
            root.iconbitmap(icon)
    except Exception:
        pass
    label = tk.Label(root, text="UnrealFX\n(OBS audio capture target)")
    label.pack(fill="both", expand=True, padx=6, pady=4)
    # Iconic/minimized stays enumerable for OBS; keeps the desktop clear.
    root.update_idletasks()
    root.iconify()
    on_ready()
    root.mainloop()


def monitor_loop(addon: str, log_path: str, stop_event: threading.Event) -> None:
    tail = LogTail(log_path)
    war_running = False
    next_war_check = 0.0
    while not stop_event.is_set():
        now = time.monotonic()
        if now >= next_war_check:
            war_running = war_client_running()
            next_war_check = now + WAR_PROCESS_CHECK_SECONDS

        if not war_running:
            tail.stop()  # next session starts at the end of the log
            stop_event.wait(POLL_SECONDS)
            continue

        for line in tail.poll(now):
            wav = wav_for_line(addon, line)
            if wav:
                play_wav(wav)
                if "scenariopop" in line.lower():
                    flash_game_window()

        stop_event.wait(POLL_SECONDS)


def main() -> int:
    addon = addon_dir()
    game_root = find_game_root(addon)
    log_dir = os.path.join(game_root, "logs")
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, "UnrealFX.log")
    seed = os.path.join(addon, "files", "UnrealFX.log")
    if not os.path.isfile(log_path) and os.path.isfile(seed):
        try:
            import shutil

            shutil.copy2(seed, log_path)
        except OSError:
            pass

    set_wave_volume(VOLUME_PERCENT)
    stop_event = threading.Event()
    worker = threading.Thread(
        target=monitor_loop,
        args=(addon, log_path, stop_event),
        name="ufx-log-monitor",
        daemon=True,
    )

    def start_monitor() -> None:
        if not worker.is_alive():
            worker.start()

    print(
        f"[UnrealFX] gameRoot={game_root} log={log_path} "
        f"window={WINDOW_TITLE!r} (OBS Application Audio Capture target)",
        flush=True,
    )
    try:
        create_obs_window(start_monitor)
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Narrator: a text-to-speech MCP server whose speaker is a browser tab.

Two ways to use it from Claude Code:

  A tour (`tour_start`, `tour_add`, `tour_wait`): a narrated walkthrough as a
  queue of stops, each a range of a file plus what to say about it. This
  process plays the stops in order, moving the highlight in Neovim itself
  (through config/nvim/lua/walkthrough.lua) as each one starts, and
  synthesising the next while the current one plays. The listener's player has
  Previous, Next, Pause and Stop/Continue.

  `speak`: one utterance, which returns once a player reports it has finished
  playing. For answering a question after the listener has stopped a tour.

Every tour is also saved, as it is written, to .tours/ in the project, and
`tour_replay` plays a saved one again without Claude writing it afresh.

Why a queue rather than Claude calling `speak` once per stop, as the first
version did: every stop then cost a full turn of the agent between the end of
one narration and the start of the next -- about 25 s of silence per stop,
measured, nearly all of it Claude composing the next stop. Stop pressed in that
gap was lost, too, because the next `speak` began afresh; and Previous could
not move the highlight back, since only Claude could move it. With the stops
queued here, Claude writes ahead while the listener listens: `tour_add`
returns at once, so the first stops play while Claude is still reading the
code for later ones, and a large codebase does not mean a long silence before
the first word. The cost is that the narrator needs its own connection to
Neovim (pynvim, to the socket the nvim-mcp plugin opens).

Why a browser rather than a sound device: the container has none, and there is
no single way to give it one. Docker Desktop for Mac cannot pass a host audio
socket through its VM at all; a Linux host could share its PulseAudio socket,
but that still leaves a phone or laptop attached over Tailscale with nothing.
A page on a published port reaches all three the same way Orca does, and needs
nothing installed on the listening side. See "Narrated walkthroughs" in
README.md.

One long-lived process serves both halves on one port (6769 in the container):

    /mcp            streamable-HTTP MCP endpoint, for Claude Code inside the
                    container only (loopback; see LoopbackOnly)
    /               the player page            } all of these need ?token=,
    /events         Server-Sent Events stream  } since the port is published
    /clip/<id>.wav  one synthesised clip       } on every interface of the host
    /started        the player: a clip started playing (moves the subtitle)
    /ended          the player: a clip finished playing
    /control        the player's buttons: prev, next, stop, continue

Long-lived rather than a stdio server that Claude Code spawns per session: two
sessions would fight over the port, the model would load (1-2 s) for every
session, and the player would lose its server whenever a session ended.

SSE plus plain fetches rather than a WebSocket: uvicorn needs an extra package
for WebSockets, and audio arriving as an ordinary GET is also what lets the
browser decode it without any framing of our own.

`narrator` (config/bin/narrator) starts and stops this; it is not meant to be
run by hand, though `python narrator.py --help` works.
"""

from __future__ import annotations

import argparse
import asyncio
import glob
import hashlib
import hmac
import io
import json
import logging
import os
import re
import secrets
import socket
import subprocess
import threading
import time
import wave
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
import pynvim
import uvicorn
from kokoro_onnx import Kokoro
from mcp.server.mcpserver import MCPServer
from pydantic import BaseModel, Field
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, Response, StreamingResponse
from starlette.types import ASGIApp, Receive, Scope, Send

log = logging.getLogger("narrator")

HERE = Path(__file__).resolve().parent

# Kept around so a player that is a clip behind can still fetch it. Far more
# than one utterance ever needs; the point is only that memory stays bounded.
# A tour's clips are not counted: they stay until the next tour, so Previous
# can replay any stop without synthesising it again.
CLIP_CACHE = 64

# How long `speak` and `tour_wait` wait before giving up. Generous on purpose:
# a listener may pause to read the code, and timing out under them would let
# Claude race ahead. Disconnects and Stop end the wait sooner. A wait that runs
# out while the listener has Pause pressed says so (see paused_note), because
# a bare "still playing after 15 minutes" read to Claude as something gone
# wrong, and it started asking the listener whether all was well.
WAIT_CAP = 15 * 60

# Text is synthesised a few sentences at a time, so the first one plays while
# the rest is still being generated. Measured on a Docker Desktop VM on Apple
# silicon: about 0.67 s of CPU per second of speech with the int8 model, so a
# whole paragraph at once would mean several seconds of silence first. Chunks
# shorter than this are merged with the next, because Kokoro's prosody is
# noticeably flatter on a fragment than on a full sentence.
MIN_CHUNK_CHARS = 60

SENTENCE_END = re.compile(r"(?<=[.!?;:])\s+")

# Where tours are saved, under the project's git root (or project_root outside
# git). The name the user's first hand-saved tours used, so those replay too.
TOURS_DIR = ".tours"

NO_PLAYER = (
    "No player is listening. Ask the user to open the player page: on the host, "
    "`./dev narrator-url` prints its address."
)


def split_text(text: str) -> list[str]:
    chunks: list[str] = []
    buf = ""
    for part in SENTENCE_END.split(" ".join(text.split())):
        buf = f"{buf} {part}".strip()
        if len(buf) >= MIN_CHUNK_CHARS:
            chunks.append(buf)
            buf = ""
    if buf:
        if chunks and len(buf) < MIN_CHUNK_CHARS // 2:
            chunks[-1] = f"{chunks[-1]} {buf}"
        else:
            chunks.append(buf)
    return chunks


def gap_after(seconds: float, end_of_stop: bool) -> float:
    """The silence the player leaves after a clip, in seconds.

    It was a flat 0.2 s, which ran sentences together. Longer after a longer
    clip, as a speaker breathes more after a long sentence than a short one:
    about 0.5 s after five seconds of speech, at most 0.8 s. A stop's last clip
    gets more again, since the highlight moves there and the eye needs a beat
    to follow it.
    """
    gap = 0.35 + min(0.45, 0.03 * seconds)
    return round(gap + (0.35 if end_of_stop else 0.0), 2)


def git(root: str, *args: str) -> str | None:
    """`git -C root ...`'s output, or None if it failed or there is no git."""
    try:
        r = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    # rstrip only: `status --porcelain` lines start with a meaningful space.
    return r.stdout.rstrip() if r.returncode == 0 else None


def file_digest(path: str) -> str | None:
    try:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()[:16]
    except OSError:
        return None


def slugify(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:60].rstrip("-") or "tour"


def to_wav(samples: np.ndarray, rate: int) -> bytes:
    """16-bit mono WAV, which every browser decodes without a codec."""
    pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2")
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())
    return out.getvalue()


@dataclass
class Clip:
    id: int
    text: str
    wav: bytes
    seconds: float
    done: asyncio.Event = field(default_factory=asyncio.Event)


class StopSpec(BaseModel):
    """One stop of a tour, as Claude sends it."""

    file: str = Field(description="Path relative to project_root, or absolute")
    first: int = Field(description="First line to highlight, 1-based")
    last: int = Field(description="Last line to highlight, inclusive")
    label: str = Field(description="A few words shown above the highlight")
    text: str = Field(description="What to say about these lines: one to four sentences, written for the ear")


@dataclass
class Stop:
    index: int
    spec: StopSpec
    clips: list[Clip] = field(default_factory=list)
    ready: asyncio.Event = field(default_factory=asyncio.Event)


class NvimLink:
    """The narrator's own connection to Neovim, for moving the highlight.

    pynvim is synchronous and not thread-safe, so every call goes through one
    dedicated thread; the event loop never blocks on Neovim. It connects to the
    socket the nvim-mcp plugin opens (see init.lua), which is a plain Neovim
    RPC socket, so no second server has to be started in the editor.
    """

    def __init__(self, root: str, path: str) -> None:
        self.root = root
        self.path: str | None = path
        self.pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="nvim")
        self.nvim: pynvim.Nvim | None = None

    def _call(self, code: str, args: tuple) -> Any:
        if self.path is None:
            self.path = NvimLink.find(self.root)
            if self.path is None:
                raise OSError("no Neovim for this project")
        try:
            if self.nvim is None:
                self.nvim = pynvim.attach("socket", path=self.path)
            return self.nvim.exec_lua(code, *args)
        except (OSError, EOFError):
            # Neovim restarted or closed: drop the handle, and the socket too,
            # since a restarted Neovim opens one under its new pid. Otherwise
            # every later stop failed with "Connection refused" on the dead
            # socket even after the listener had opened Neovim again.
            self._close()
            self.path = None
            raise

    async def lua(self, code: str, *args: Any) -> Any:
        return await asyncio.get_running_loop().run_in_executor(self.pool, self._call, code, args)

    def _close(self) -> None:
        if self.nvim is None:
            return
        nvim, self.nvim = self.nvim, None
        # pynvim 0.6.0's close() only schedules the transport's close on its
        # private event loop, then closes that loop without running it again,
        # so the socket stays open and Neovim keeps the channel. Shutting the
        # socket down first makes Neovim see EOF and drop it. Measured: three
        # tours left six RPC channels before this, none after.
        try:
            transport = nvim._session._async_session.loop._transport  # noqa: SLF001
            transport.get_extra_info("socket").shutdown(socket.SHUT_RDWR)
        except Exception:  # noqa: BLE001 -- already gone is as good as closed
            pass
        try:
            nvim.close()
        except Exception:  # noqa: BLE001
            pass

    async def close(self) -> None:
        """Hang up, so a finished tour's connection does not outlive it.

        Every open connection is one more RPC channel in Neovim, and Neovim
        0.12.6 segfaults broadcasting to five or more (see the rpcnotify
        workaround in init.lua). Each tour_start used to leave the previous
        tour's connection open, and the second tour of a session was enough.
        """
        await asyncio.get_running_loop().run_in_executor(self.pool, self._close)
        self.pool.shutdown(wait=False)

    @staticmethod
    def find(project_root: str) -> str | None:
        """The newest live nvim-mcp socket for this project root.

        The plugin names it /tmp/nvim-mcp.<git root with / as %>.<pid>.sock
        (the v0.7.2 scheme the nvim-mcp server globs for too). project_root
        and its ancestors are tried nearest first: Claude has passed the
        project's main package rather than its working directory, and the
        socket is named after the repository. Failing that, a single live
        socket on the machine is taken as the one meant. Only live ones count:
        a Neovim that crashed leaves its socket behind, and that stale file
        once made two candidates, so no highlight for the next session.
        """
        def live(paths: list[str]) -> list[str]:
            alive = []
            for path in sorted(paths, key=os.path.getmtime, reverse=True):
                # A bare connect, not pynvim.attach: pynvim's close() leaves
                # the socket open (see _close), so every probe used to stay
                # behind in Neovim as an RPC channel.
                with socket.socket(socket.AF_UNIX) as s:
                    try:
                        s.connect(path)
                        alive.append(path)
                    except OSError:
                        continue
            return alive

        root = os.path.realpath(project_root).rstrip("/") or "/"
        while True:
            mine = live(glob.glob(f"/tmp/nvim-mcp.{glob.escape(root.replace('/', '%'))}.*.sock"))
            if mine:
                return mine[0]
            if root == "/":
                break
            root = os.path.dirname(root)
        others = live(glob.glob("/tmp/nvim-mcp.*.sock"))
        return others[0] if len(others) == 1 else None


class TourFile:
    """A tour as saved under .tours/, so it can be replayed without Claude
    writing it again (`tour_replay`).

    Saved by the narrator rather than left to Claude, which saved them only
    when asked and in whatever shape it chose that day. Rewritten whole after
    every tour_add, so a tour the listener abandoned half way is still a valid
    file with the stops written so far, and `complete` says whether Claude got
    to the end.

    The stops are kept exactly as Claude sent them, and their line numbers only
    mean something against the code they were written for. A tour need not be
    about a commit -- it may be about uncommitted work or a diff -- so that is
    recorded several ways: `commit` and `branch` as they were when the tour
    started, `dirty` (what `git status` listed then), `basis` (Claude's own
    words, when it said the tour was about something else), and `files`, a
    digest of every narrated file as it was when its first stop arrived. The
    digests are what tour_replay checks, since they hold however the tour came
    about; a hand-saved tour with only `commit` is checked with `git diff`.
    """

    def __init__(self, title: str, root: str, basis: str | None) -> None:
        self.title = title
        self.root = root
        self.basis = basis
        self.top = git(root, "rev-parse", "--show-toplevel")
        self.dir = Path(self.top or root) / TOURS_DIR
        self.commit = git(root, "rev-parse", "--short", "HEAD") if self.top else None
        self.branch = git(root, "rev-parse", "--abbrev-ref", "HEAD") if self.commit else None
        status = git(root, "status", "--porcelain") if self.top else None
        self.dirty = [line[3:] for line in status.splitlines()] if status else []
        self.created = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
        self.files: dict[str, str | None] = {}
        self.path: Path | None = None
        # tour_add saves from worker threads, and two in quick succession could
        # finish out of order; the stop count tells a stale snapshot apart.
        self.lock = threading.Lock()
        self.written = -1

    def _choose_path(self) -> Path:
        self.dir.mkdir(parents=True, exist_ok=True)
        self._exclude()
        stem = f"{self.created[:10]}-{slugify(self.title)}"
        for n in range(1, 1000):
            path = self.dir / (f"{stem}.json" if n == 1 else f"{stem}-{n}.json")
            try:
                # Created exclusively, so a second tour of the same title the
                # same day gets a name of its own instead of overwriting.
                path.touch(exist_ok=False)
                return path
            except FileExistsError:
                continue
        raise OSError(f"no free file name for {stem} in {self.dir}")

    def _exclude(self) -> None:
        """Keep .tours/ out of `git status` and out of commits, unless the
        project already says otherwise (ignores it, or tracks tours on purpose).

        .git/info/exclude rather than .gitignore: it is local to this clone and
        changes no file of the project's. Checked after the directory exists,
        because git matches a pattern with a trailing slash only against a
        directory that is there.
        """
        if not self.top or git(self.top, "check-ignore", "-q", TOURS_DIR + "/") is not None:
            return
        if git(self.top, "ls-files", TOURS_DIR):
            return
        exclude = git(self.top, "rev-parse", "--git-path", "info/exclude")
        if not exclude:
            return
        path = Path(self.top) / exclude
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as f:
            f.write(f"\n# saved narrated walkthroughs (narrator)\n/{TOURS_DIR}/\n")

    def save(self, stops: list[StopSpec], complete: bool) -> Path:
        with self.lock:
            if len(stops) < self.written:
                return self.path  # type: ignore[return-value]
            for spec in stops:
                if spec.file not in self.files:
                    path = spec.file if os.path.isabs(spec.file) else os.path.join(self.root, spec.file)
                    self.files[spec.file] = file_digest(path)
            if self.path is None:
                self.path = self._choose_path()
            head: dict[str, Any] = {
                "title": self.title,
                "project_root": self.root,
                "commit": self.commit,
                "branch": self.branch,
            }
            if self.basis:
                head["basis"] = self.basis
            if self.dirty:
                head["dirty"] = self.dirty
            head |= {"created": self.created, "complete": complete, "files": self.files}
            # One stop per line, like the tours first saved by hand: a diff of
            # two versions of a tour, or a skim of one, reads stop by stop.
            lines = ["{"]
            lines += [f"  {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}," for k, v in head.items()]
            lines.append('  "stops": [')
            lines.append(",\n".join("    " + json.dumps(s.model_dump(), ensure_ascii=False) for s in stops))
            lines += ["  ]", "}", ""]
            tmp = self.path.with_suffix(".json.tmp")
            tmp.write_text("\n".join(lines))
            os.replace(tmp, self.path)
            self.written = len(stops)
            return self.path


def tour_drift(data: dict, root: str) -> list[str] | None:
    """Narrated files changed since a saved tour was written, or None if there
    is no way to tell (a hand-saved tour whose commit git does not know)."""
    files = data.get("files") or {}
    if files:
        return [
            rel for rel, digest in files.items()
            if file_digest(rel if os.path.isabs(rel) else os.path.join(root, rel)) != digest
        ]
    if data.get("commit"):
        rels = sorted({s["file"] for s in data.get("stops", [])})
        out = git(root, "diff", "--name-only", data["commit"], "--", *rels)
        return None if out is None else out.splitlines()
    return None


class Tour:
    def __init__(self, title: str, root: str, nvim: NvimLink | None) -> None:
        self.title = title
        self.root = root
        self.nvim = nvim
        # Where the tour is being saved; None for a replay, or if saving failed.
        self.file: TourFile | None = None
        # The clip whose text the subtitle shows, so two players reporting the
        # same start do not redraw it twice.
        self.subtitled: int | None = None
        self.stops: list[Stop] = []
        self.pos = 0
        # Claude has sent the last stop.
        self.complete = False
        # "playing", "stopped" (the listener pressed Stop) or "finished".
        self.state = "playing"
        # Where Previous or Next asked to go, picked up by the driver.
        self.jump: int | None = None
        # The listener stopped since Claude last heard about it.
        self.stop_unreported = False

    def where(self) -> str:
        if not self.stops:
            return "no stops yet"
        i = min(self.pos, len(self.stops) - 1)
        return f"stop {i + 1} of {len(self.stops)} ({self.stops[i].spec.label!r})"


class Narrator:
    def __init__(self, kokoro: Kokoro, voice: str, speed: float) -> None:
        self.kokoro = kokoro
        self.model_name = "kokoro"
        self.voice = voice
        self.speed = speed
        self.clips: OrderedDict[int, Clip] = OrderedDict()
        self.pinned: set[int] = set()
        self.next_id = 1
        self.players: set[asyncio.Queue[dict]] = set()
        # Replaced on every change worth re-checking (a player came or went, a
        # button was pressed, a stop was added or synthesised), so anything
        # waiting wakes up and looks again. Waiters take it *before* checking
        # their condition, so a change in between is never missed.
        self.wake = asyncio.Event()
        self.stopped_by_listener = False
        # When a player pressed Pause, or None. Pause itself stays in the page
        # (it suspends that page's audio, and the server just waits for the
        # clip to end); the page reports it only so Claude can be told.
        self.paused_since: float | None = None
        self.tour: Tour | None = None
        self.tasks: list[asyncio.Task] = []
        self.background: set[asyncio.Task] = set()
        # One utterance at a time. Two interleaved would be unintelligible,
        # and the second caller's wait would end on the first one's audio.
        self.lock = asyncio.Lock()
        # Kokoro is not documented as thread-safe; synthesis runs in a worker
        # thread, one at a time.
        self.synth_lock = asyncio.Lock()

    # -- plumbing ------------------------------------------------------------

    def broadcast(self, event: dict) -> None:
        for q in self.players:
            q.put_nowait(event)

    def poke(self) -> None:
        self.wake.set()
        self.wake = asyncio.Event()

    async def wait_any(self, wake: asyncio.Event, *events: asyncio.Event, timeout: float | None = None) -> None:
        waits = [asyncio.ensure_future(e.wait()) for e in (wake, *events)]
        try:
            await asyncio.wait(waits, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for w in waits:
                w.cancel()

    async def synth(self, text: str, voice: str, speed: float, pin: bool = False) -> Clip:
        async with self.synth_lock:
            t = time.monotonic()
            samples, rate = await asyncio.to_thread(
                self.kokoro.create, text, voice=voice, speed=speed, lang="en-us"
            )
        clip = Clip(self.next_id, text, to_wav(samples, rate), len(samples) / rate)
        self.next_id += 1
        log.info("clip %d: %.1fs of audio in %.1fs", clip.id, clip.seconds, time.monotonic() - t)
        self.clips[clip.id] = clip
        if pin:
            self.pinned.add(clip.id)
        unpinned = [i for i in self.clips if i not in self.pinned]
        for i in unpinned[: max(0, len(unpinned) - CLIP_CACHE)]:
            del self.clips[i]
        return clip

    def state_event(self) -> dict:
        t = self.tour
        if t is None:
            return {"type": "state", "tour": None}
        current = t.stops[min(t.pos, len(t.stops) - 1)].spec.label if t.stops else ""
        return {
            "type": "state",
            "tour": {
                "title": t.title,
                "state": t.state,
                "index": t.pos,
                "total": len(t.stops),
                "complete": t.complete,
                "label": current,
            },
        }

    def paused_note(self) -> str:
        if self.paused_since is None:
            return ""
        minutes = (time.monotonic() - self.paused_since) / 60
        ago = "just now" if minutes < 1 else f"{minutes:.0f} min ago"
        return (
            f"The listener pressed Pause {ago} and has not resumed: they are reading or "
            "away, which is expected. Do not prompt them; playback carries on when they resume."
        )

    def announce(self) -> None:
        self.broadcast(self.state_event())
        self.poke()

    # -- single utterances ---------------------------------------------------

    async def speak(self, text: str, voice: str | None, speed: float | None, wait: bool) -> str:
        voice = voice or self.voice
        if voice not in self.kokoro.get_voices():
            return f"Unknown voice {voice!r}. Voices: {', '.join(self.kokoro.get_voices())}"
        if self.tour and self.tour.state == "playing":
            return (
                "A tour is playing, and speech now would talk over it. Add to the tour "
                "with tour_add instead, or wait for it with tour_wait."
            )
        chunks = split_text(text)
        if not chunks:
            return "Nothing to say: the text was empty."
        if not self.players:
            return NO_PLAYER + " Then call speak again."
        async with self.lock:
            self.stopped_by_listener = False
            last: Clip | None = None
            for chunk in chunks:
                if self.stopped_by_listener:
                    break
                clip = await self.synth(chunk, voice, speed or self.speed)
                # Checked again: Stop may have arrived during synthesis, and a
                # clip sent after it would play once the player has flushed.
                if self.stopped_by_listener:
                    break
                last = clip
                self.broadcast(self.clip_event(clip, False))
            if last is None or (self.stopped_by_listener and not wait):
                return "The listener pressed Stop before it was spoken. Ask them how to continue."
            if not wait:
                return "Queued."
            return await self.wait_for(last)

    async def wait_for(self, clip: Clip) -> str:
        deadline = time.monotonic() + WAIT_CAP
        while True:
            wake = self.wake
            if clip.done.is_set():
                return "Spoken."
            if self.stopped_by_listener:
                return "The listener pressed Stop. Ask them how to continue; do not carry on speaking."
            if not self.players:
                return "The player disconnected before playback finished."
            left = deadline - time.monotonic()
            if left <= 0:
                if self.paused_since is not None:
                    return self.paused_note() + " Not spoken yet; it plays on resume."
                return "Gave up waiting for playback after 15 minutes."
            await self.wait_any(wake, clip.done, timeout=left)

    # -- tours ---------------------------------------------------------------

    async def open_tour(self, project_root: str, title: str) -> str | None:
        """Replace any tour with an empty one; returns the Neovim socket found."""
        for task in self.tasks:
            task.cancel()
        self.tasks = []
        if self.tour and self.tour.nvim:
            await self.highlight_clear(self.tour)
            await self.tour.nvim.close()
        self.pinned.clear()
        self.broadcast({"type": "flush"})
        path = await asyncio.to_thread(NvimLink.find, project_root)
        self.tour = Tour(title, project_root, NvimLink(project_root, path) if path else None)
        self.tasks = [asyncio.create_task(self.synth_worker(self.tour)), asyncio.create_task(self.drive(self.tour))]
        self.announce()
        return path

    @staticmethod
    def nvim_note(path: str | None) -> str:
        return (
            f"Neovim found at {path}; each stop's lines are highlighted as it plays."
            if path
            else "No Neovim for this project was found, so the highlight will not move; "
            "the narration still plays. Ask the user to open nvim in the project if they want it."
        )

    async def tour_start(self, project_root: str, title: str, basis: str | None) -> str:
        path = await self.open_tour(project_root, title)
        t = self.tour
        notes = [f"Tour {title!r} started.", self.nvim_note(path)]
        try:
            t.file = await asyncio.to_thread(TourFile, title, project_root, basis)
            notes.append(f"It is saved under {t.file.dir} as you add stops.")
        except Exception as e:  # noqa: BLE001 -- an unsaved tour still plays
            log.warning("cannot save tour %r: %s", title, e)
        if not self.players:
            notes.append(NO_PLAYER + " Stops will wait for it.")
        notes.append("Add the first stops now with tour_add, so playback can begin.")
        return " ".join(notes)

    async def tour_replay(self, path: str, project_root: str | None) -> str:
        try:
            data = json.loads(Path(path).read_text())
            specs = [StopSpec(**s) for s in data["stops"]]
        except (OSError, ValueError, KeyError, TypeError) as e:
            return f"Cannot replay {path}: {e}"
        if not specs:
            return f"{path} has no stops."
        # The project may have moved since (another container, another mount
        # point). The tours directory sits in the project root, so its parent
        # is the next best guess.
        root = project_root or data.get("project_root") or ""
        if not os.path.isdir(root):
            root = str(Path(path).resolve().parent.parent)
        title = data.get("title") or Path(path).stem
        nvim = await self.open_tour(root, title)
        t = self.tour
        t.stops = [Stop(i, spec) for i, spec in enumerate(specs)]
        t.complete = True
        self.announce()
        notes = [f"Replaying {title!r}, {len(specs)} stops, from {root}.", self.nvim_note(nvim)]
        if data.get("complete") is False:
            notes.append("It was saved before Claude finished writing it, so it may end abruptly.")
        changed = await asyncio.to_thread(tour_drift, data, root)
        if changed:
            notes.append(
                "These files have changed since the tour was saved, so their highlights may "
                f"be off by a few lines: {', '.join(changed)}."
            )
        elif changed is None:
            notes.append("There is no record of the code it was written for, so it cannot tell whether the files have changed.")
        if not self.players:
            notes.append(NO_PLAYER + " Playback waits for it.")
        notes.append("Call tour_wait to follow it.")
        return " ".join(notes)

    async def tour_add(self, stops: list[StopSpec], last: bool) -> str:
        t = self.tour
        if t is None:
            return "No tour is open. Start one with tour_start."
        if t.complete:
            return "This tour was already marked complete; start a new one with tour_start."
        bad = [s.label for s in stops if not s.text.strip()]
        if bad:
            return f"Nothing was added: these stops have no text: {bad}"
        for spec in stops:
            t.stops.append(Stop(len(t.stops), spec))
        t.complete = last
        self.announce()
        report = self.tour_report(t)
        if t.file:
            try:
                await asyncio.to_thread(t.file.save, [s.spec for s in t.stops], t.complete)
            except Exception as e:  # noqa: BLE001
                log.warning("saving tour %r failed: %s", t.title, e)
                report += f" (Saving the tour to {t.file.dir} failed: {e}; playback is unaffected.)"
        return report

    def tour_report(self, t: Tour) -> str:
        played = min(t.pos, len(t.stops))
        ahead = len(t.stops) - played
        parts = [f"{len(t.stops)} stops queued; now at {t.where()}; {ahead} not yet heard."]
        if t.stop_unreported or t.state == "stopped":
            t.stop_unreported = False
            parts.append(
                f"The listener pressed Stop at {t.where()}. Stop adding stops and ask them "
                "what they would like: answer questions in chat or with speak, then "
                "tour_resume to carry on."
            )
        elif t.state == "finished":
            parts.append("The tour has finished playing.")
        elif not t.complete:
            parts.append(
                ("The listener is about to run out: add the next stops soon."
                 if ahead <= 1 else "Add the next stops when they are ready.")
                + " Mark the final batch with last=true."
            )
        if not self.players:
            parts.append(NO_PLAYER)
        elif note := self.paused_note():
            parts.append(note)
        return " ".join(parts)

    async def tour_wait(self) -> str:
        t = self.tour
        if t is None:
            return "No tour is open."
        deadline = time.monotonic() + WAIT_CAP
        while True:
            wake = self.wake
            if t is not self.tour:
                return "A new tour replaced this one."
            if t.state == "finished":
                return f"The tour finished: all {len(t.stops)} stops were heard."
            if t.state == "stopped":
                t.stop_unreported = False
                return (
                    f"The listener pressed Stop at {t.where()}. Ask them what they would like: "
                    "answer questions in chat or with speak, then call tour_resume and "
                    "tour_wait to carry on (they can also press Continue in the player)."
                )
            if t.pos >= len(t.stops) and not t.complete:
                return (
                    "The listener has heard every stop queued so far. Add more with tour_add "
                    "(last=true on the final batch), then tour_wait again."
                )
            if not self.players:
                return NO_PLAYER + " The tour is paused until one connects."
            left = deadline - time.monotonic()
            if left <= 0:
                if self.paused_since is not None:
                    return f"At {t.where()}. {self.paused_note()} Call tour_wait again."
                return f"Still playing after 15 minutes, at {t.where()}; call tour_wait again."
            await self.wait_any(wake, timeout=left)

    def tour_resume(self) -> str:
        t = self.tour
        if t is None:
            return "No tour is open."
        if t.state == "stopped":
            self.control("continue")
            return f"Resumed at {t.where()}. Call tour_wait to follow it."
        return f"The tour is {t.state}, at {t.where()}; nothing to resume."

    async def synth_worker(self, t: Tour) -> None:
        """Synthesise every queued stop, the current one and those after it first."""
        while True:
            wake = self.wake
            pending = [s for s in t.stops[t.pos:] + t.stops[: t.pos] if not s.ready.is_set()]
            if not pending:
                await self.wait_any(wake)
                continue
            stop = pending[0]
            for chunk in split_text(stop.spec.text):
                stop.clips.append(await self.synth(chunk, self.voice, self.speed, pin=True))
            stop.ready.set()
            self.poke()

    async def highlight(self, t: Tour, stop: Stop) -> None:
        if not t.nvim:
            return
        s = stop.spec
        path = s.file if os.path.isabs(s.file) else os.path.join(t.root, s.file)
        try:
            await t.nvim.lua(
                "return require('walkthrough').show(...)", path, s.first, s.last, s.label
            )
        except Exception as e:  # noqa: BLE001 -- a lost highlight must not stop the tour
            log.warning("highlight failed for stop %d: %s", stop.index + 1, e)

    async def subtitle(self, t: Tour, text: str | None) -> None:
        if t.nvim:
            try:
                await t.nvim.lua("return require('walkthrough').subtitle(...)", text)
            except Exception as e:  # noqa: BLE001 -- subtitles are a nicety
                log.warning("subtitle failed: %s", e)

    def spawn(self, coro: Any) -> None:
        """Fire and forget, keeping a reference so the task is not collected."""
        task = asyncio.create_task(coro)
        self.background.add(task)
        task.add_done_callback(self.background.discard)

    def clip_started(self, clip: Clip) -> None:
        """A player started playing `clip`: show its text as the subtitle in
        Neovim. Driven by the player rather than by sending the clip, since a
        stop's clips are all sent at once and the player plays them in turn."""
        t = self.tour
        if t is None or t.nvim is None or t.subtitled == clip.id:
            return
        if not any(clip in s.clips for s in t.stops):
            return
        t.subtitled = clip.id
        self.spawn(self.subtitle(t, clip.text))

    def clip_event(self, clip: Clip, end_of_stop: bool) -> dict:
        return {"type": "clip", "id": clip.id, "text": clip.text, "gap": gap_after(clip.seconds, end_of_stop)}

    async def highlight_clear(self, t: Tour) -> None:
        if t.nvim:
            try:
                await t.nvim.lua("return require('walkthrough').clear()")
            except Exception as e:  # noqa: BLE001
                log.warning("clearing the highlight failed: %s", e)

    async def drive(self, t: Tour) -> None:
        """Play the tour: highlight a stop, send its clips, wait for the last to end."""
        while True:
            wake = self.wake
            if t.jump is not None:
                t.pos, t.jump = t.jump, None
                self.announce()
                continue
            if t.state == "finished":
                return
            if t.state == "stopped" or not self.players:
                await self.wait_any(wake)
                continue
            if t.pos >= len(t.stops):
                if t.complete:
                    t.state = "finished"
                    await self.highlight_clear(t)
                    self.announce()
                    return
                await self.wait_any(wake)
                continue
            stop = t.stops[t.pos]
            if not stop.ready.is_set():
                await self.wait_any(wake, stop.ready)
                continue

            await self.highlight(t, stop)
            t.subtitled = None
            self.announce()
            for clip in stop.clips:
                clip.done.clear()
                self.broadcast(self.clip_event(clip, clip is stop.clips[-1]))
            last = stop.clips[-1]
            # Until the last clip ends, or something else needs the driver.
            while True:
                wake = self.wake
                if last.done.is_set() or t.jump is not None or t.state != "playing" or not self.players:
                    break
                await self.wait_any(wake, last.done)
            if last.done.is_set() and t.jump is None and t.state == "playing":
                t.pos += 1
                self.announce()
            # Otherwise the loop top handles the jump, the stop or the missing
            # player, and a stop that was cut short is played again from its
            # start when the tour carries on.

    def control(self, action: str) -> None:
        """A player button. Previous and Next jump within a tour; Stop holds it."""
        if action in ("pause", "resume"):
            # Recorded, not acted on: waking Claude for a pause would defeat it.
            if action == "pause":
                self.paused_since = self.paused_since or time.monotonic()
            else:
                self.paused_since = None
            log.info("listener pressed %s", action.capitalize())
            return
        t = self.tour
        # Previous still means something once a tour has finished: hear its
        # last stop again. Otherwise the buttons act on a plain `speak`.
        if t is None or (t.state == "finished" and action != "prev"):
            if action == "stop":
                self.stopped_by_listener = True
                self.broadcast({"type": "flush"})
                self.poke()
            elif action == "next":
                self.broadcast({"type": "skip"})
            return
        self.broadcast({"type": "flush"})
        if action == "prev":
            target = max(0, min(t.pos, len(t.stops)) - 1)
            if t.state == "finished":
                # Back into a finished tour: play its last stop again.
                t.state = "playing"
                self.tasks.append(asyncio.create_task(self.drive(t)))
            t.jump = target
        elif action == "next":
            t.jump = min(t.pos + 1, len(t.stops))
        elif action == "stop" and t.state == "playing":
            t.state = "stopped"
            t.stop_unreported = True
            # The highlight stays, as the place being asked about; the
            # subtitle would be a sentence that is no longer being spoken.
            t.subtitled = None
            self.spawn(self.subtitle(t, None))
            log.info("listener pressed Stop at %s", t.where())
        elif action == "continue" and t.state == "stopped":
            t.state = "playing"
        self.announce()

    def player_joined(self) -> None:
        # A stop's clips went out before this player was listening, so it
        # would wait for audio it never got. Start the stop again for everyone.
        if self.tour and self.tour.state == "playing" and self.tour.pos < len(self.tour.stops):
            self.broadcast({"type": "flush"})
            self.tour.jump = self.tour.pos
        self.poke()


class LoopbackOnly:
    """Refuse /mcp to anything but loopback.

    The port is published on every host interface for the player's sake, and
    the MCP endpoint must not come with it: anyone on your LAN could otherwise
    make the container talk. Traffic through the published port arrives from
    Docker's gateway address, never from 127.0.0.1, so this check is exact.
    The SDK's own DNS-rebinding guard (on for host 127.0.0.1) covers browsers.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http" and scope["path"].startswith("/mcp"):
            host = (scope.get("client") or ("", 0))[0]
            if host not in ("127.0.0.1", "::1"):
                await Response("MCP is only served to the container itself\n", 403)(scope, receive, send)
                return
        await self.app(scope, receive, send)


def load_token(path: Path) -> str:
    """The player's shared secret, kept across restarts of this process.

    Not across a recreated container, which comes back without the file: an
    open player tab then needs the new URL from `./dev narrator-url`.
    """
    try:
        token = path.read_text().strip()
        if token:
            return token
    except FileNotFoundError:
        pass
    token = secrets.token_urlsafe(18)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(token + "\n")
    path.chmod(0o600)
    return token


def build_app(narrator: Narrator, token: str) -> ASGIApp:
    mcp = MCPServer(
        "narrator",
        instructions=(
            "Speaks to the user through a browser player page, and plays narrated code "
            "walkthroughs. For a walkthrough use a tour: tour_start, then tour_add a few "
            "stops at a time as you write them (it returns at once and playback starts "
            "straight away), last=true on the final batch, then tour_wait. Tours are saved "
            "under .tours/ in the project; tour_replay plays a saved one. Use speak only "
            "for a single remark, such as answering a question after the listener stops."
        ),
    )

    @mcp.tool()
    async def tour_start(project_root: str, title: str, basis: str | None = None) -> str:
        """Begin a narrated walkthrough, replacing any previous one.

        `project_root` is your working directory (absolute); stop paths are
        relative to it, and it is how the narrator finds the user's Neovim to
        move the highlight. The tour is saved under .tours/ in the project as
        stops are added, with the current commit recorded; `basis` says what
        the line numbers refer to when that is not simply the checked-out
        commit, e.g. "uncommitted changes to the parser" or "the diff from
        main to feature-x". Follow with tour_add.
        """
        return await narrator.tour_start(project_root, title, basis)

    @mcp.tool()
    async def tour_add(stops: list[StopSpec], last: bool = False) -> str:
        """Queue stops on the open tour. Returns at once; playback runs meanwhile.

        Send the first one or two stops as soon as they are written so the
        listener is not left waiting, then keep adding in small batches while
        you read on. Each stop is highlighted in Neovim while its text is
        spoken. Pass last=true with the final batch. The reply says where the
        listener is, and whether they pressed Stop.
        """
        return await narrator.tour_add(stops, last)

    @mcp.tool()
    async def tour_replay(path: str, project_root: str | None = None) -> str:
        """Play a tour saved earlier (a .tours/*.json file), replacing any tour.

        `path` is absolute. `project_root` overrides the one in the file, for a
        project that has moved; by default the file's, else the directory
        above .tours/. The reply says whether the narrated files have changed
        since. Follow with tour_wait, as for a tour you wrote.
        """
        return await narrator.tour_replay(path, project_root)

    @mcp.tool()
    async def tour_wait() -> str:
        """Block until the tour finishes, the listener presses Stop, or every queued stop has been heard."""
        return await narrator.tour_wait()

    @mcp.tool()
    async def tour_resume() -> str:
        """Carry on a tour the listener stopped, from the stop they stopped at."""
        return narrator.tour_resume()

    @mcp.tool()
    async def speak(text: str, voice: str | None = None, speed: float | None = None, wait: bool = True) -> str:
        """Say `text` aloud in the user's player page, outside a tour.

        For a single remark, such as answering a question once the listener has
        stopped a tour; refused while a tour is playing. Blocks until the player
        has finished it (when `wait` is true, the default). Write for the ear:
        no markdown, no code symbols read out character by character.
        `voice` is a Kokoro voice id (see `status`); `speed` defaults to 1.0.
        """
        return await narrator.speak(text, voice, speed, wait)

    @mcp.tool()
    async def stop() -> str:
        """Stop playback at once: holds a playing tour, or cuts a speak short."""
        narrator.control("stop")
        return "Stopped."

    @mcp.tool()
    async def status() -> dict:
        """Whether a player is listening or paused, the tour's progress, and the voices available."""
        return {
            "players_connected": len(narrator.players),
            "player_url_hint": "run ./dev narrator-url on the host",
            "tour": narrator.state_event()["tour"],
            # A paused tour is the listener reading, not something stuck.
            "paused": narrator.paused_since is not None,
            "paused_note": narrator.paused_note() or None,
            "model": narrator.model_name,
            "voice": narrator.voice,
            "speed": narrator.speed,
            "voices": narrator.kokoro.get_voices(),
        }

    def authorised(request: Request) -> bool:
        given = request.query_params.get("token", "")
        return hmac.compare_digest(given.encode(), token.encode())

    denied = Response("Wrong or missing token. On the host: ./dev narrator-url\n", 403)

    async def page(request: Request) -> Response:
        if not authorised(request):
            return denied
        return HTMLResponse((HERE / "player.html").read_text())

    async def events(request: Request) -> Response:
        if not authorised(request):
            return denied
        q: asyncio.Queue[dict] = asyncio.Queue()
        q.put_nowait({"type": "hello", "voice": narrator.voice})
        q.put_nowait(narrator.state_event())
        narrator.players.add(q)
        narrator.player_joined()
        log.info("player connected from %s (%d now)", request.client and request.client.host, len(narrator.players))

        async def stream():
            try:
                while True:
                    try:
                        event = await asyncio.wait_for(q.get(), timeout=15)
                        yield f"data: {json.dumps(event)}\n\n"
                    except asyncio.TimeoutError:
                        # Keeps proxies and phones from dropping an idle stream,
                        # and is how a vanished client gets noticed.
                        yield ": ping\n\n"
            finally:
                narrator.players.discard(q)
                if not narrator.players:
                    # Nobody left to resume it; "no player" is the news now.
                    narrator.paused_since = None
                narrator.poke()
                log.info("player disconnected (%d left)", len(narrator.players))

        return StreamingResponse(
            stream(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
        )

    async def clip(request: Request) -> Response:
        if not authorised(request):
            return denied
        c = narrator.clips.get(int(request.path_params["id"]))
        if c is None:
            return Response("gone\n", 404)
        return Response(c.wav, media_type="audio/wav", headers={"Cache-Control": "no-store"})

    async def ended(request: Request) -> Response:
        if not authorised(request):
            return denied
        c = narrator.clips.get(int((await request.json()).get("id", 0)))
        if c is not None:
            c.done.set()
        return JSONResponse({"ok": True})

    async def started(request: Request) -> Response:
        if not authorised(request):
            return denied
        c = narrator.clips.get(int((await request.json()).get("id", 0)))
        if c is not None:
            narrator.clip_started(c)
        return JSONResponse({"ok": True})

    async def control(request: Request) -> Response:
        if not authorised(request):
            return denied
        action = (await request.json()).get("action", "")
        if action not in ("prev", "next", "stop", "continue", "pause", "resume"):
            return JSONResponse({"ok": False, "error": f"unknown action {action!r}"}, 400)
        narrator.control(action)
        return JSONResponse({"ok": True})

    for path, endpoint, methods in (
        ("/", page, ["GET"]),
        ("/events", events, ["GET"]),
        ("/clip/{id:int}.wav", clip, ["GET"]),
        ("/started", started, ["POST"]),
        ("/ended", ended, ["POST"]),
        ("/control", control, ["POST"]),
    ):
        mcp.custom_route(path, methods=methods)(endpoint)

    return LoopbackOnly(mcp.streamable_http_app(host="127.0.0.1"))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=6769)
    p.add_argument("--model", required=True, help="kokoro .onnx model")
    p.add_argument("--voices", required=True, help="kokoro voices .bin")
    p.add_argument("--voice", default="af_heart")
    p.add_argument("--speed", type=float, default=1.0)
    p.add_argument("--token-file", type=Path, required=True)
    args = p.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    # "words count mismatch on 100.0% of the lines" on nearly every clip, from
    # espeak splitting words differently from phonemizer; the audio is fine.
    logging.getLogger("phonemizer").setLevel(logging.ERROR)
    t = time.monotonic()
    kokoro = Kokoro(args.model, args.voices)
    log.info("model loaded in %.1fs", time.monotonic() - t)
    narrator = Narrator(kokoro, args.voice, args.speed)
    # The Dockerfile writes the --narrator-model choice beside the model, which
    # is otherwise always called kokoro.onnx.
    marker = Path(args.model).with_name("MODEL")
    narrator.model_name = marker.read_text().strip() if marker.exists() else Path(args.model).name
    app = build_app(narrator, load_token(args.token_file))
    # Read by `narrator start` to know the server is up.
    log.info("listening on %s:%d", args.host, args.port)
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()

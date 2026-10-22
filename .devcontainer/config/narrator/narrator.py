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
import hmac
import io
import json
import logging
import os
import re
import secrets
import time
import wave
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
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
# Claude race ahead. Disconnects and Stop end the wait sooner.
WAIT_CAP = 15 * 60

# Text is synthesised a few sentences at a time, so the first one plays while
# the rest is still being generated. Measured on a Docker Desktop VM on Apple
# silicon: about 0.67 s of CPU per second of speech with the int8 model, so a
# whole paragraph at once would mean several seconds of silence first. Chunks
# shorter than this are merged with the next, because Kokoro's prosody is
# noticeably flatter on a fragment than on a full sentence.
MIN_CHUNK_CHARS = 60

SENTENCE_END = re.compile(r"(?<=[.!?;:])\s+")

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
            self.nvim = None
            self.path = None
            raise

    async def lua(self, code: str, *args: Any) -> Any:
        return await asyncio.get_running_loop().run_in_executor(self.pool, self._call, code, args)

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
                try:
                    pynvim.attach("socket", path=path).close()
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


class Tour:
    def __init__(self, title: str, root: str, nvim: NvimLink | None) -> None:
        self.title = title
        self.root = root
        self.nvim = nvim
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
        self.tour: Tour | None = None
        self.tasks: list[asyncio.Task] = []
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
                self.broadcast({"type": "clip", "id": last.id, "text": last.text})
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
                return "Gave up waiting for playback after 15 minutes."
            await self.wait_any(wake, clip.done, timeout=left)

    # -- tours ---------------------------------------------------------------

    async def tour_start(self, project_root: str, title: str) -> str:
        for task in self.tasks:
            task.cancel()
        self.tasks = []
        if self.tour and self.tour.nvim:
            await self.highlight_clear(self.tour)
        self.pinned.clear()
        self.broadcast({"type": "flush"})
        path = await asyncio.to_thread(NvimLink.find, project_root)
        self.tour = Tour(title, project_root, NvimLink(project_root, path) if path else None)
        self.tasks = [asyncio.create_task(self.synth_worker(self.tour)), asyncio.create_task(self.drive(self.tour))]
        self.announce()
        notes = [f"Tour {title!r} started."]
        notes.append(
            f"Neovim found at {path}; each stop's lines are highlighted as it plays."
            if path
            else "No Neovim for this project was found, so the highlight will not move; "
            "the narration still plays. Ask the user to open nvim in the project if they want it."
        )
        if not self.players:
            notes.append(NO_PLAYER + " Stops will wait for it.")
        notes.append("Add the first stops now with tour_add, so playback can begin.")
        return " ".join(notes)

    def tour_add(self, stops: list[StopSpec], last: bool) -> str:
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
        return self.tour_report(t)

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
            self.announce()
            for clip in stop.clips:
                clip.done.clear()
                self.broadcast({"type": "clip", "id": clip.id, "text": clip.text})
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
            "straight away), last=true on the final batch, then tour_wait. Use speak only "
            "for a single remark, such as answering a question after the listener stops."
        ),
    )

    @mcp.tool()
    async def tour_start(project_root: str, title: str) -> str:
        """Begin a narrated walkthrough, replacing any previous one.

        `project_root` is your working directory (absolute); stop paths are
        relative to it, and it is how the narrator finds the user's Neovim to
        move the highlight. Follow with tour_add.
        """
        return await narrator.tour_start(project_root, title)

    @mcp.tool()
    async def tour_add(stops: list[StopSpec], last: bool = False) -> str:
        """Queue stops on the open tour. Returns at once; playback runs meanwhile.

        Send the first one or two stops as soon as they are written so the
        listener is not left waiting, then keep adding in small batches while
        you read on. Each stop is highlighted in Neovim while its text is
        spoken. Pass last=true with the final batch. The reply says where the
        listener is, and whether they pressed Stop.
        """
        return narrator.tour_add(stops, last)

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
        """Whether a player is listening, the tour's progress, and the voices available."""
        return {
            "players_connected": len(narrator.players),
            "player_url_hint": "run ./dev narrator-url on the host",
            "tour": narrator.state_event()["tour"],
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

    async def control(request: Request) -> Response:
        if not authorised(request):
            return denied
        action = (await request.json()).get("action", "")
        if action not in ("prev", "next", "stop", "continue"):
            return JSONResponse({"ok": False, "error": f"unknown action {action!r}"}, 400)
        narrator.control(action)
        return JSONResponse({"ok": True})

    for path, endpoint, methods in (
        ("/", page, ["GET"]),
        ("/events", events, ["GET"]),
        ("/clip/{id:int}.wav", clip, ["GET"]),
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

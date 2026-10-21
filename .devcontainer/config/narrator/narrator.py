"""Narrator: a text-to-speech MCP server whose speaker is a browser tab.

Claude Code calls `speak`; this process synthesises the text with Kokoro and
hands the audio to every player page that is connected, and `speak` returns
only once a player reports that the last of it has finished playing. That
return is what keeps a narrated walkthrough in step: Claude highlights a range
in Neovim, speaks about it, and moves on only when you have heard it.

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
    /ended, /stopped  the player's reports back

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
import hmac
import io
import json
import logging
import re
import secrets
import time
import wave
from collections import OrderedDict
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import uvicorn
from kokoro_onnx import Kokoro
from mcp.server.mcpserver import MCPServer
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, Response, StreamingResponse
from starlette.types import ASGIApp, Receive, Scope, Send

log = logging.getLogger("narrator")

HERE = Path(__file__).resolve().parent

# Kept around so a player that is a clip behind can still fetch it. Far more
# than one utterance ever needs; the point is only that memory stays bounded.
CLIP_CACHE = 64

# How long `speak` waits for playback before giving up. Generous on purpose: a
# listener may pause mid-sentence to read the code, and timing out under them
# would let Claude race ahead. Disconnects and Stop end the wait sooner.
SPEAK_WAIT_CAP = 15 * 60

# Text is synthesised a few sentences at a time, so the first one plays while
# the rest is still being generated. Measured on a Docker Desktop VM on Apple
# silicon: about 0.67 s of CPU per second of speech with the int8 model, so a
# whole paragraph at once would mean several seconds of silence first. Chunks
# shorter than this are merged with the next, because Kokoro's prosody is
# noticeably flatter on a fragment than on a full sentence.
MIN_CHUNK_CHARS = 60

SENTENCE_END = re.compile(r"(?<=[.!?;:])\s+")


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


class Narrator:
    def __init__(self, kokoro: Kokoro, voice: str, speed: float) -> None:
        self.kokoro = kokoro
        self.voice = voice
        self.speed = speed
        self.clips: OrderedDict[int, Clip] = OrderedDict()
        self.next_id = 1
        self.players: set[asyncio.Queue[dict]] = set()
        # Set when the players change or a listener presses Stop, so a waiting
        # `speak` re-checks why it is waiting.
        self.wake = asyncio.Event()
        self.stopped_by_listener = False
        # One utterance at a time. Two interleaved would be unintelligible,
        # and the second caller's wait would end on the first one's audio.
        self.lock = asyncio.Lock()
        # Kokoro is not documented as thread-safe; synthesis runs in a worker
        # thread, one at a time.
        self.synth_lock = asyncio.Lock()

    def broadcast(self, event: dict) -> None:
        for q in self.players:
            q.put_nowait(event)

    def poke(self) -> None:
        self.wake.set()
        self.wake = asyncio.Event()

    async def synth(self, text: str, voice: str, speed: float) -> Clip:
        async with self.synth_lock:
            t = time.monotonic()
            samples, rate = await asyncio.to_thread(
                self.kokoro.create, text, voice=voice, speed=speed, lang="en-us"
            )
        clip = Clip(self.next_id, text, to_wav(samples, rate), len(samples) / rate)
        self.next_id += 1
        log.info("clip %d: %.1fs of audio in %.1fs", clip.id, clip.seconds, time.monotonic() - t)
        self.clips[clip.id] = clip
        while len(self.clips) > CLIP_CACHE:
            self.clips.popitem(last=False)
        return clip

    async def speak(self, text: str, voice: str | None, speed: float | None, wait: bool) -> str:
        voice = voice or self.voice
        if voice not in self.kokoro.get_voices():
            return f"Unknown voice {voice!r}. Voices: {', '.join(self.kokoro.get_voices())}"
        chunks = split_text(text)
        if not chunks:
            return "Nothing to say: the text was empty."
        if not self.players:
            return (
                "No player is listening, so nothing was spoken. Ask the user to open the "
                "player page: on the host, `./dev narrator-url` prints its address. "
                "Then call speak again."
            )
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
        deadline = time.monotonic() + SPEAK_WAIT_CAP
        while True:
            if clip.done.is_set():
                return "Spoken."
            if self.stopped_by_listener:
                return (
                    "The listener pressed Stop. Pause the walkthrough and ask them how "
                    "to continue; do not carry on speaking."
                )
            if not self.players:
                return "The player disconnected before playback finished."
            left = deadline - time.monotonic()
            if left <= 0:
                return "Gave up waiting for playback after 15 minutes."
            wake = self.wake
            done = asyncio.ensure_future(clip.done.wait())
            woke = asyncio.ensure_future(wake.wait())
            await asyncio.wait({done, woke}, timeout=left, return_when=asyncio.FIRST_COMPLETED)
            done.cancel()
            woke.cancel()

    def stop(self) -> None:
        self.stopped_by_listener = True
        self.broadcast({"type": "stop"})
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
            "Speaks text aloud to the user through a browser player page. Keep each "
            "speak call to one idea (one to four sentences) about code you have just "
            "shown, and let it finish before moving the highlight on."
        ),
    )

    @mcp.tool()
    async def speak(text: str, voice: str | None = None, speed: float | None = None, wait: bool = True) -> str:
        """Say `text` aloud in the user's player page.

        Blocks until the player has finished playing it (when `wait` is true, the
        default), so code you highlight before the call stays on screen while it
        is being explained. Write for the ear: no markdown, no code symbols read
        out character by character; say "the setup function", not "cmd_setup()".
        `voice` is a Kokoro voice id (see `status`); `speed` defaults to 1.0.
        """
        return await narrator.speak(text, voice, speed, wait)

    @mcp.tool()
    async def stop() -> str:
        """Stop playback at once and drop anything still queued."""
        narrator.stop()
        return "Stopped."

    @mcp.tool()
    async def status() -> dict:
        """Whether a player is listening, plus the current voice and the voices available."""
        return {
            "players_connected": len(narrator.players),
            "player_url_hint": "run ./dev narrator-url on the host",
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
        narrator.players.add(q)
        narrator.poke()
        log.info("player connected from %s (%d now)", request.client and request.client.host, len(narrator.players))

        async def stream():
            try:
                yield f"data: {json.dumps({'type': 'hello', 'voice': narrator.voice})}\n\n"
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

    async def stopped(request: Request) -> Response:
        if not authorised(request):
            return denied
        log.info("listener pressed Stop")
        narrator.stop()
        return JSONResponse({"ok": True})

    for path, endpoint, methods in (
        ("/", page, ["GET"]),
        ("/events", events, ["GET"]),
        ("/clip/{id:int}.wav", clip, ["GET"]),
        ("/ended", ended, ["POST"]),
        ("/stopped", stopped, ["POST"]),
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
    app = build_app(narrator, load_token(args.token_file))
    # Read by `narrator start` to know the server is up.
    log.info("listening on %s:%d", args.host, args.port)
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()

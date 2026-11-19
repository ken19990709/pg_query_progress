#!/usr/bin/env python3
"""Live-capture a psql progress-bar session and render it as a GIF.

This script records a REAL interactive psql session (spawned on a
pseudo-terminal against a cluster bootstrapped by tests/bootstrap.sh),
timestamping every byte that comes back, and then replays those bytes
through a minimal VT100-subset terminal emulator to produce the frames
of assets/demo.gif.  Nothing in the frames is synthesized: every glyph
shown comes from the captured psql output, including the ANSI
single-line bar redraw sequences (ESC[2K CR / ESC[1A ESC[2K CR)
emitted by the extension's bar renderer.

Usage (cluster lifecycle is the caller's job):

    # 1. build + boot a throwaway instance (see tests/bootstrap.sh)
    PG_CONFIG=/path/to/pg_config PGQP_SCALE=1.0 tests/bootstrap.sh

    # 2. capture + render
    python3 scripts/make_demo_gif.py tests/.pgqp_env.sh

    # 3. tear the instance down again
    tests/bootstrap.sh --down

Re-render an earlier capture (no cluster needed):

    python3 scripts/make_demo_gif.py --replay /tmp/pgqp_bar_capture.jsonl

Dependencies: python3 and Pillow (pip install pillow).  Everything
else (psql, the connection env) comes from the bootstrap env file.
Note the env file names a psql under PGQP_BINDIR which may not be on
PATH; the script invokes it by full path.

The typed demo session (all real keystrokes):

    \\timing on
    SET pg_query_progress.bar = on;
    SET pg_query_progress.bar_interval_ms = 300;
    SELECT count(*) FROM big_table, generate_series(1, <mult>);

which scans big_table <mult> times (a cross join against a small
generate_series row multiplier), long enough for a smooth 0-100
percent climb at the 300 ms frame interval.
"""

import argparse
import base64
import codecs
import fcntl
import json
import os
import pty
import random
import select
import subprocess
import sys
import time

BLOCK = chr(0x2588)              # full block, the bar's filled cell
SHADE = chr(0x2591)              # light shade, the bar's empty cell

BG = (11, 14, 20)                # terminal background
FG = (214, 222, 233)             # default bright text
BAR_FILLED = (74, 226, 131)      # green for filled bar cells
BAR_EMPTY = (64, 72, 88)         # dim slate for empty bar cells
CURSOR = (62, 74, 96)            # blinking block cursor
PAD = 8                          # frame border padding, px

TERMINAL_COLS = 72               # pty viewport the emulator shows
TERMINAL_ROWS = 13

INTRO_LINES = [
    "\\timing on",
    "SET pg_query_progress.bar = on;",
    "SET pg_query_progress.bar_interval_ms = 300;",
]

QUERY = "SELECT count(*) FROM big_table, generate_series(1, %d);"


def parse_env_file(path):
    """Parse the KEY="value" exports written by tests/bootstrap.sh."""
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("export "):
                key, val = line[len("export "):].split("=", 1)
                env[key] = val.strip().strip('"')
    return env


# ---------------------------------------------------------------------------
# Phase 1: live capture on a pty
# ---------------------------------------------------------------------------

def capture(env_file, mult, interval_ms, type_cps, jsonl_path, tail_s):
    """Run the demo session in a pty and record timestamped bytes."""
    env = parse_env_file(env_file)
    psql = os.path.join(env.get("PGQP_BINDIR", ""), "psql")
    if not os.path.isfile(psql):
        sys.exit("make_demo_gif: no psql in PGQP_BINDIR (%r); "
                 "did tests/bootstrap.sh write this env file?" % psql)

    child_env = dict(os.environ)
    for key in ("PGHOST", "PGPORT", "PGUSER", "PGDATABASE",
                "LD_LIBRARY_PATH"):
        if key in env:
            child_env[key] = env[key]
    child_env["TERM"] = "xterm-256color"
    child_env["LC_ALL"] = "C"

    mfd, sfd = pty.openpty()
    child = subprocess.Popen(
        [psql, "-X", "--set=PROMPT1=pgqp=# "],
        stdin=sfd, stdout=sfd, stderr=sfd,
        env=child_env, start_new_session=True, close_fds=True)
    os.close(sfd)
    fcntl.fcntl(mfd, fcntl.F_SETFL,
                fcntl.fcntl(mfd, fcntl.F_GETFL) | os.O_NONBLOCK)

    events = []                  # (monotonic t, "i"|"o", bytes)
    alive = [True]

    def pump(duration):
        """Read master bytes for `duration` seconds (EOF-tolerant).
        duration=0 does a single drain pass (the tty echo of a
        keystroke is queued synchronously by the master write)."""
        end = time.monotonic() + duration
        while True:
            remaining = end - time.monotonic()
            timeout = 0.0 if duration <= 0 else max(0.0, min(0.02,
                                                             remaining))
            ready, _, _ = select.select([mfd], [], [], timeout)
            if ready:
                try:
                    data = os.read(mfd, 65536)
                except (BlockingIOError, OSError):
                    alive[0] = False
                    return
                if not data:
                    alive[0] = False
                    return
                events.append((time.monotonic(), "o", data))
            if time.monotonic() >= end:
                return

    def type_line(text, cps):
        rng = random.Random(97)
        for ch in text:
            if not alive[0]:
                return
            try:
                os.write(mfd, ch.encode())
            except OSError:
                alive[0] = False
                return
            events.append((time.monotonic(), "i", ch.encode()))
            time.sleep(cps * (0.7 + 0.6 * rng.random()))
            pump(0.0)            # pick up the echo right away so its
                                 # timestamp matches the keystroke
        os.write(mfd, b"\n")
        events.append((time.monotonic(), "i", b"\n"))
        time.sleep(0.22)
        pump(0.0)

    try:
        t0 = time.monotonic()
        pump(0.5)                                    # welcome banner
        lines = list(INTRO_LINES)
        lines[-1] = "SET pg_query_progress.bar_interval_ms = %d;" % \
            interval_ms
        for line in lines:
            type_line(line, type_cps)
        type_line(QUERY % mult, type_cps)
        # the query runs ~ mult x 0.1 s; wait for the result table and
        # the returning prompt, then linger `tail_s` on the final frame.
        # "(1 row)" is the unambiguous end marker (with \\timing on the
        # SET commands print their own "Time:" lines too).
        deadline = time.monotonic() + mult * 0.1 + 30.0
        done = False
        out = b""
        while time.monotonic() < deadline and alive[0]:
            pump(0.1)
            out = b"".join(e[2] for e in events if e[1] == "o")
            if b"(1 row)" in out[-200:] and b"pgqp=# " in out[-80:]:
                done = True
                break
        if not done:
            sys.stderr.write("make_demo_gif: warning: final prompt not "
                             "observed before timeout\n")
        pump(tail_s)
    finally:
        try:
            child.terminate()
            child.wait(timeout=3)
        except Exception:
            child.kill()
            child.wait()
        try:
            os.close(mfd)
        except OSError:
            pass

    recs = [[round(t - t0, 4), io, base64.b64encode(b).decode()]
            for (t, io, b) in events]
    with open(jsonl_path, "w") as f:
        for rec in recs:
            f.write(json.dumps(rec) + "\n")
    # the tail linger keeps the final tableau on screen: the duration
    # is the last event PLUS the tail, so the GIF holds the last frame
    duration = max(rec[0] for rec in recs) + tail_s
    print("capture: %d chunks, %.2f s -> %s" %
          (len(recs), duration, jsonl_path))
    return duration


def load_events(jsonl_path):
    events = []
    with open(jsonl_path) as f:
        for line in f:
            t, io, b64 = json.loads(line)
            events.append((float(t), io, base64.b64decode(b64)))
    return events


# ---------------------------------------------------------------------------
# Phase 2: minimal terminal emulator.  It implements the VT subset a
# psql session with the bar actually uses -- CR, LF, BS, TAB, and the
# CSI sequences 1A (up) / 2K (erase line) -- and parses-and-ignores
# anything else, so real byte streams can never produce fabricated
# frame content.
# ---------------------------------------------------------------------------

class Screen:
    def __init__(self):
        self.rows = [[]]         # list of char lists; rows grow lazily
        self.r = 0
        self.c = 0
        self.scroll = 0          # top visible row; only ever increases
        self._utf = codecs.getincrementaldecoder("utf-8")("replace")
        self._pend = ""          # partial escape sequence tail

    # -- grid helpers ------------------------------------------------------
    def _ensure(self):
        while self.r >= len(self.rows):
            self.rows.append([])
        row = self.rows[self.r]
        while len(row) <= self.c:
            row.append(" ")

    def put(self, ch):
        self._ensure()
        self.rows[self.r][self.c] = ch
        self.c += 1

    def newline(self):
        self.r += 1
        self.c = 0
        if self.r - self.scroll >= TERMINAL_ROWS:
            self.scroll = self.r - TERMINAL_ROWS + 1
        self._ensure()

    # -- byte stream -------------------------------------------------------
    def feed(self, data):
        text = self._pend + self._utf.decode(data)
        self._pend = ""
        # keep a trailing partial ESC sequence for the next chunk
        esc = text.rfind("\x1b")
        if esc != -1:
            tail = text[esc:]
            if not self._complete_csi(tail):
                self._pend = tail
                text = text[:esc]
        self._parse(text)

    @staticmethod
    def _complete_csi(tail):
        # "ESC [ <params> <final>" or two-char ESC sequences
        if len(tail) < 2:
            return False
        if tail[1] != "[":
            return len(tail) >= 3 or tail[1] in "()#"
        for ch in tail[2:]:
            if ch not in "0123456789;?<=>":
                return True
        return False

    def _parse(self, text):
        i = 0
        n = len(text)
        while i < n:
            ch = text[i]
            if ch == "\x1b":
                i = self._csi(text, i)
            elif ch == "\r":
                self.c = 0
                i += 1
            elif ch == "\n":
                self.newline()
                i += 1
            elif ch == "\b":
                self.c = max(0, self.c - 1)
                i += 1
            elif ch == "\t":
                self.c = min(TERMINAL_COLS - 1, (self.c // 8 + 1) * 8)
                i += 1
            elif ch in ("\x07", "\x00"):
                i += 1
            else:
                self.put(ch)
                i += 1

    def _csi(self, text, i):
        """Handle one escape sequence; return the next index."""
        n = len(text)
        if i + 1 >= n:
            return n
        if text[i + 1] != "[":               # ESC ) X, ESC ( X, ESC =
            return min(n, i + 3)
        j = i + 2
        while j < n and text[j] in "0123456789;?":
            j += 1
        if j >= n:                            # truncated: caller stashed
            return n
        params = text[i + 2:j]
        cmd = text[j]
        args = []
        for p in params.lstrip("?").split(";"):
            args.append(int(p) if p.isdigit() else 0)
        num = args[0] if args and args[0] else 1
        if cmd == "A":                        # cursor up
            self.r = max(self.scroll, self.r - num)
        elif cmd == "B":                      # cursor down
            self.r += num
            self._ensure()
        elif cmd == "C":                      # cursor right
            self.c += num
        elif cmd == "D":                      # cursor left
            self.c = max(0, self.c - num)
        elif cmd == "G":                      # column, absolute
            self.c = max(0, num - 1)
        elif cmd == "K":                      # erase in line
            self._ensure()
            row = self.rows[self.r]
            mode = args[0] if args else 0
            if mode == 0:
                for k in range(self.c, len(row)):
                    row[k] = " "
            else:
                end = len(row) if mode == 2 else self.c
                for k in range(0, min(end, len(row))):
                    row[k] = " "
                if mode == 2:
                    self.c = 0
        elif cmd == "J" and args and args[0] == 2:
            self.rows = [[]]                  # erase entire display
            self.r = self.c = self.scroll = 0
        # any other sequence (m, h, l, ...): parsed and ignored
        return j + 1

    # -- snapshot ----------------------------------------------------------
    def window(self):
        """The TERMINAL_ROWS x TERMINAL_COLS viewport (bottom-anchored)."""
        top = max(0, min(self.scroll,
                         max(0, len(self.rows) - TERMINAL_ROWS)))
        lines = []
        for r in range(top, top + TERMINAL_ROWS):
            row = self.rows[r] if r < len(self.rows) else []
            line = "".join(row[:TERMINAL_COLS])
            lines.append(line.ljust(TERMINAL_COLS))
        return lines, self.r - top, min(self.c, TERMINAL_COLS - 1)


# ---------------------------------------------------------------------------
# Phase 3: Pillow rendering
# ---------------------------------------------------------------------------

def find_font(override):
    if override:
        return override
    candidates = []
    try:
        out = subprocess.run(["fc-match", "-f", "%{file}", "DejaVu Sans Mono"],
                             capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip():
            candidates.append(out.stdout.strip())
    except Exception:
        pass
    candidates += ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
                   "/usr/share/fonts/TTF/DejaVuSansMono.ttf"]
    for path in candidates:
        if path and os.path.isfile(path):
            return path
    sys.exit("make_demo_gif: no monospace font found "
             "(try --font /path/to/font.ttf)")


class Glyphs:
    """Pre-rendered opaque cell bitmaps, keyed by (char, color)."""

    def __init__(self, font_path, font_size):
        from PIL import Image, ImageDraw, ImageFont
        self.Image = Image
        font = ImageFont.truetype(font_path, font_size)
        self.cw = max(1, int(font.getlength("M") + 0.999))
        asc, desc = font.getmetrics()
        self.chh = int((asc + desc) * 1.06 + 0.999)
        self.cache = {}
        self._font = font

    def cell(self, ch, color):
        key = (ch, color)
        img = self.cache.get(key)
        if img is None:
            from PIL import ImageDraw
            img = self.Image.new("RGB", (self.cw, self.chh), BG)
            bbox = self._font.getbbox(ch)
            if bbox and bbox[2] > bbox[0]:
                w = bbox[2] - bbox[0]
                h = bbox[3] - bbox[1]
                x = (self.cw - w) // 2 - bbox[0]
                y = (self.chh - h) // 2 - bbox[1]
                ImageDraw.Draw(img).text((x, y), ch, font=self._font,
                                         fill=color)
            self.cache[key] = img
        return img

    @staticmethod
    def char_color(ch):
        if ch == BLOCK:
            return BAR_FILLED
        if ch == SHADE:
            return BAR_EMPTY
        return FG


def replay_screen(events, tick):
    """Advance a fresh screen to time `tick`; used for both frames and
    PNG dumps."""
    screen = Screen()
    for (t, io, b) in events:
        if io != "o":
            continue
        if t > tick:
            break
        screen.feed(b)
    return screen


def draw_screen(screen, glyphs):
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (PAD * 2 + TERMINAL_COLS * glyphs.cw,
                            PAD * 2 + TERMINAL_ROWS * glyphs.chh), BG)
    lines, cur_r, cur_c = screen.window()
    for r, line in enumerate(lines):
        y = PAD + r * glyphs.chh
        for c, ch in enumerate(line):
            if ch != " ":
                img.paste(glyphs.cell(ch, Glyphs.char_color(ch)),
                          (PAD + c * glyphs.cw, y))
    x = PAD + cur_c * glyphs.cw
    y = PAD + cur_r * glyphs.chh
    ImageDraw.Draw(img).rectangle(
        [x, y, x + glyphs.cw - 1, y + glyphs.chh - 1], outline=CURSOR)
    return img


def render_frames(events, duration, fps, font_path, font_size):
    """Snapshot the screen at each frame tick and draw it."""
    glyphs = Glyphs(font_path, font_size)
    frames = []
    step = 1.0 / fps
    nframes = int(duration / step) + 1
    for fi in range(nframes):
        tick = fi * step
        screen = replay_screen(events, tick)
        img = draw_screen_nocursor(screen, glyphs)
        # cursor blink, ~530 ms half-period like a real terminal
        if int(tick * 1000) // 530 % 2 == 0:
            draw_cursor(img, glyphs, screen.window()[1:])
        frames.append(img)
    return frames, glyphs


def draw_screen_nocursor(screen, glyphs):
    from PIL import Image
    img = Image.new("RGB", (PAD * 2 + TERMINAL_COLS * glyphs.cw,
                            PAD * 2 + TERMINAL_ROWS * glyphs.chh), BG)
    lines, _, _ = screen.window()
    for r, line in enumerate(lines):
        y = PAD + r * glyphs.chh
        for c, ch in enumerate(line):
            if ch != " ":
                img.paste(glyphs.cell(ch, Glyphs.char_color(ch)),
                          (PAD + c * glyphs.cw, y))
    return img


def draw_cursor(img, glyphs, pos):
    from PIL import ImageDraw
    cur_r, cur_c = pos
    x = PAD + cur_c * glyphs.cw
    y = PAD + cur_r * glyphs.chh
    ImageDraw.Draw(img).rectangle(
        [x, y, x + glyphs.cw - 1, y + glyphs.chh - 1], outline=CURSOR)


def save_gif(frames, out_path, fps, palette_colors):
    """Quantize every frame onto one shared palette, then write the GIF."""
    if not frames:
        sys.exit("make_demo_gif: no frames rendered")
    from PIL import Image
    # master palette from a spread of frames (typing, early bar, late
    # bar, result): enough variety that no frame needs colors outside it
    picks = sorted(set(int(i * (len(frames) - 1) / 5) for i in range(6)))
    stack = Image.new("RGB", (frames[0].width * 3, frames[0].height * 2),
                      BG)
    for slot, pick in enumerate(picks):
        stack.paste(frames[pick], ((slot % 3) * frames[0].width,
                                   (slot // 3) * frames[0].height))
    master = stack.quantize(colors=palette_colors, method=Image.MEDIANCUT,
                            dither=Image.Dither.NONE)
    pal_frames = [f.quantize(palette=master, dither=Image.Dither.NONE)
                  for f in frames]
    duration_ms = int(round(1000.0 / fps))
    pal_frames[0].save(out_path, save_all=True,
                       append_images=pal_frames[1:],
                       duration=duration_ms, loop=0)
    return len(pal_frames), duration_ms


def main():
    ap = argparse.ArgumentParser(
        description="Live-capture the psql progress bar into a GIF.",
        epilog="The env file is the one tests/bootstrap.sh writes "
               "(tests/.pgqp_env.sh by default).")
    ap.add_argument("env_file", nargs="?", default=None,
                    help="bootstrap env file (default: tests/.pgqp_env.sh "
                         "relative to the repository root)")
    ap.add_argument("--replay", metavar="JSONL",
                    help="render from an earlier capture instead of "
                         "running psql")
    ap.add_argument("--out", default=None,
                    help="output GIF path (default: assets/demo.gif "
                         "relative to the repository root)")
    ap.add_argument("--capture", default=None,
                    help="where to keep the timestamped byte capture "
                         "(default: /tmp/pgqp_bar_capture.jsonl)")
    ap.add_argument("--mult", type=int, default=130,
                    help="generate_series multiplier of the demo query "
                         "(query duration ~= mult x 0.1 s)")
    ap.add_argument("--interval-ms", type=int, default=300,
                    help="bar_interval_ms for the demo session")
    ap.add_argument("--fps", type=float, default=8.0,
                    help="output frame rate (default 8)")
    ap.add_argument("--type-cps", type=float, default=0.012,
                    help="seconds per typed character")
    ap.add_argument("--tail", type=float, default=1.4,
                    help="linger on the final frame, seconds")
    ap.add_argument("--font-size", type=int, default=17,
                    help="monospace font size in px")
    ap.add_argument("--font", default=None, help="monospace font file")
    ap.add_argument("--palette-colors", type=int, default=64,
                    help="shared GIF palette size")
    ap.add_argument("--png-dir", default=None,
                    help="also dump PNG frames here")
    ap.add_argument("--png-times", default="",
                    help="comma-separated capture seconds to dump as PNG")
    args = ap.parse_args()

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    if args.replay:
        events = load_events(args.replay)
        duration = (max(t for (t, _, _) in events) + args.tail
                    if events else 0.0)
    else:
        env_file = args.env_file or os.path.join(repo_root,
                                                 "tests", ".pgqp_env.sh")
        if not os.path.isfile(env_file):
            sys.exit("make_demo_gif: env file missing: %s\n"
                     "  boot an instance first: tests/bootstrap.sh" %
                     env_file)
        cap = args.capture or "/tmp/pgqp_bar_capture.jsonl"
        duration = capture(env_file, args.mult, args.interval_ms,
                           args.type_cps, cap, args.tail)
        events = load_events(cap)

    font_path = find_font(args.font)
    frames, glyphs = render_frames(events, duration, args.fps,
                                   font_path, args.font_size)
    out = args.out or os.path.join(repo_root, "assets", "demo.gif")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    n, dur_ms = save_gif(frames, out, args.fps, args.palette_colors)
    print("render: %d frames @ %d ms (%.1f fps), %dx%d px, cell %dx%d" %
          (n, dur_ms, 1000.0 / dur_ms, frames[0].width, frames[0].height,
           glyphs.cw, glyphs.chh))
    print("render: %s = %.2f MB, %.1f s of playback" %
          (out, os.path.getsize(out) / 1e6, n * dur_ms / 1000.0))

    if args.png_dir and args.png_times:
        os.makedirs(args.png_dir, exist_ok=True)
        wanted = sorted(float(x) for x in args.png_times.split(",")
                        if x.strip())
        for t in wanted:
            img = draw_screen(replay_screen(events, t), glyphs)
            png = os.path.join(args.png_dir,
                               "t%05d.png" % round(t * 1000))
            img.save(png)
            print("png: %s (t=%.2f s)" % (png, t))


if __name__ == "__main__":
    main()

"""
cdp.py - the thinnest Chrome DevTools Protocol client that will do the job.

WHY THIS EXISTS
  The daily reel (build-reel.ps1) renders scenes it authors itself, so `chrome --screenshot=` is
  enough: one page, one frame, no interaction. A product demo is the opposite job. It has to load
  the LIVE recipe page, tap the real serving stepper, switch the real cost tabs and untick the real
  "already have it" boxes, and photograph the page between each one. One-shot `--screenshot=` cannot
  do that, and neither can any flag: driving a remote page needs a live connection to the browser.

  Playwright would do this in ten lines. It also wants a 130 MB second copy of Chromium on a machine
  that already has Chrome, and the estate's rule is free-and-local with as few moving parts as
  possible. CDP over a websocket is ~150 lines and uses the Chrome that is already installed.

WHAT IT GIVES YOU
  start()                  launch headless Chrome on a private profile + debug port, attach to a tab
  goto(url)               navigate and wait for load
  js(expr)                evaluate an expression in the page, return the JSON value
  on_new_document(src)    run a script BEFORE any page script (used to kill the join interstitial)
  shot(path, clip)        PNG at the configured device scale, viewport or an arbitrary page rect
  metrics(w, h, dsf)      emulate a phone: CSS width/height plus device pixel ratio
  close()

TRAP: Chrome silently ignores a launch if another instance owns the same profile directory - the
process exits, the port never opens, and the failure looks like a timeout. Every launch here gets a
throwaway --user-data-dir for that reason (same trap the daily reel hit with --screenshot).
"""
import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

import websocket  # websocket-client


CHROME_CANDIDATES = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
]


def find_chrome():
    for p in CHROME_CANDIDATES:
        if os.path.exists(p):
            return p
    p = shutil.which("chrome")
    if p:
        return p
    raise RuntimeError("Could not find chrome.exe")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Chrome:
    def __init__(self, headless=True, width=375, height=812, dsf=3.0, verbose=False,
                 profile_dir=None, mobile=True):
        """
        profile_dir  None (default) = a throwaway profile, deleted on close. This is right for the
                     reel and the demo, which drive our own public pages and want a clean browser
                     every time.
                     A PATH = a PERSISTENT profile that is reused and NOT deleted. The grocery
                     browser pull needs this: the walled stores identify the Omaha store/club from
                     cookies, and a throwaway profile would silently capture some default store's
                     prices - a wrong-store price is worse than no price at all.
        mobile       False renders as a desktop browser. The stores serve a different (and for our
                     purposes, richer) page to a desktop viewport, and the pull agents parse the
                     desktop payload.
        Both default to the previous behaviour, so the reel and demo callers are unchanged.
        """
        self.headless = headless
        self.width, self.height, self.dsf = width, height, dsf
        self.verbose = verbose
        self.profile_dir = profile_dir
        self.mobile = mobile
        self._own_profile = profile_dir is None
        self._id = 0
        self.proc = None
        self.ws = None
        self.profile = None

    # ---------------------------------------------------------------- lifecycle

    def start(self):
        port = free_port()
        if self.profile_dir:
            os.makedirs(self.profile_dir, exist_ok=True)
            self.profile = self.profile_dir
        else:
            self.profile = tempfile.mkdtemp(prefix="tc-demo-chrome-")
        args = [
            find_chrome(),
            f"--remote-debugging-port={port}",
            # Chrome 111+ rejects a websocket whose Origin it did not issue, and websocket-client
            # always sends one. Without this the handshake dies with a 403 that says nothing about
            # the page you were trying to drive.
            "--remote-allow-origins=*",
            f"--user-data-dir={self.profile}",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions",
            "--disable-background-networking",
            "--disable-features=Translate,MediaRouter",
            "--hide-scrollbars",
            "--force-color-profile=srgb",
            "--font-render-hinting=none",
            f"--window-size={self.width},{self.height}",
            "about:blank",
        ]
        if self.headless:
            args.insert(1, "--headless=new")
            args.insert(2, "--disable-gpu")
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        deadline = time.time() + 30
        target = None
        while time.time() < deadline:
            try:
                raw = urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=2).read()
                for t in json.loads(raw):
                    if t.get("type") == "page":
                        target = t
                        break
                if target:
                    break
            except Exception:
                time.sleep(0.25)
        if not target:
            raise RuntimeError("Chrome never opened a debugging port")

        self.ws = websocket.create_connection(target["webSocketDebuggerUrl"], timeout=60,
                                              max_size=64 * 1024 * 1024)
        self.send("Page.enable")
        self.send("Runtime.enable")
        self.send("Network.enable")
        # A desktop caller must NOT get a mobile emulation override: setDeviceMetricsOverride with
        # mobile=True changes the UA-CH hints and the layout the site serves, and the grocery pull
        # agents parse the desktop payload.
        if self.mobile:
            self.metrics(self.width, self.height, self.dsf)
        return self

    def close(self):
        try:
            if self.ws:
                self.ws.close()
        except Exception:
            pass
        try:
            if self.proc:
                self.proc.terminate()
                self.proc.wait(timeout=10)
        except Exception:
            pass
        # Only remove a profile WE created. Deleting a persistent one would throw away the store
        # cookies that make the next run land on the right Omaha store.
        if self.profile and self._own_profile:
            shutil.rmtree(self.profile, ignore_errors=True)

    def __enter__(self):
        return self.start()

    def __exit__(self, *a):
        self.close()

    # ---------------------------------------------------------------- protocol

    def send(self, method, **params):
        self._id += 1
        mid = self._id
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error'].get('message')}")
                return msg.get("result", {})
            # events stream on the same socket; we only care about them for logging
            if self.verbose and "method" in msg:
                print("  ev", msg["method"], file=sys.stderr)

    # ---------------------------------------------------------------- page

    def metrics(self, width, height, dsf):
        self.width, self.height, self.dsf = width, height, dsf
        self.send("Emulation.setDeviceMetricsOverride", width=width, height=height,
                  deviceScaleFactor=dsf, mobile=True,
                  screenWidth=width, screenHeight=height)

    def on_new_document(self, source):
        self.send("Page.addScriptToEvaluateOnNewDocument", source=source)

    def goto(self, url, wait_ms=1200):
        self.send("Page.navigate", url=url)
        deadline = time.time() + 45
        while time.time() < deadline:
            state = self.js("document.readyState")
            if state == "complete":
                break
            time.sleep(0.2)
        time.sleep(wait_ms / 1000.0)

    def js(self, expr, await_promise=False):
        r = self.send("Runtime.evaluate", expression=expr, returnByValue=True,
                      awaitPromise=await_promise)
        if r.get("exceptionDetails"):
            det = r["exceptionDetails"]
            msg = det.get("exception", {}).get("description") or det.get("text")
            raise RuntimeError(f"page JS threw: {msg}\n  expr: {expr[:200]}")
        return r.get("result", {}).get("value")

    def wait_for(self, expr, timeout=20, label=None):
        """Poll a boolean expression. A demo that photographs a half-rendered widget is worse than
        one that fails, because the still looks plausible and ships a wrong number."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.js(expr):
                return True
            time.sleep(0.2)
        raise RuntimeError(f"timed out waiting for {label or expr}")

    def shot(self, path, clip=None, quality=None):
        """Viewport capture, or an arbitrary page rect given clip=(x, y, w, h) in CSS px.

        clip's `scale` is NOT the device scale factor. Emulation already renders at the emulated
        DPR, so a clip capture comes out at dsf x CSS size with scale=1; passing dsf here multiplies
        it a second time and yields a 3110px-wide image where 1080 was wanted. Left at 1."""
        params = {"format": "png", "captureBeyondViewport": bool(clip)}
        if clip:
            x, y, w, h = clip
            params["clip"] = {"x": x, "y": y, "width": w, "height": h, "scale": 1}
        r = self.send("Page.captureScreenshot", **params)
        data = base64.b64decode(r["data"])
        with open(path, "wb") as fh:
            fh.write(data)
        return path

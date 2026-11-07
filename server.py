#!/usr/bin/env python3
"""M.A.C.K. (MacMon): live Mac resource server. Python standard library only.

Run:  python3 server.py   then open http://localhost:8765/war  (the 3D war room)
                                    or http://localhost:8765      (the compact dashboard)

Environment:  PORT (default 8765), MACMON_HOST (override the hostname shown on screen)
The server only listens on 127.0.0.1.
"""
import ctypes
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", 8765))
HISTORY = 3600  # samples (1/s => 1 hour)
SAVE = os.path.expanduser("~/Library/Application Support/MacMon/history.json")
HERE = os.path.dirname(os.path.abspath(__file__))

libc = ctypes.CDLL("/usr/lib/libSystem.dylib")
libc.mach_host_self.restype = ctypes.c_uint


def sh(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ""


def sysctl(name):
    return sh("sysctl", "-n", name).strip()


def cpu_ticks():
    buf = (ctypes.c_uint * 4)()
    cnt = ctypes.c_uint(4)
    libc.host_statistics(libc.mach_host_self(), 3, buf, ctypes.byref(cnt))
    return list(buf)  # user, system, idle, nice


def memory():
    total = int(sysctl("hw.memsize"))
    page = int(sysctl("hw.pagesize") or 16384)
    vm = {k: int(v) for k, v in re.findall(r"Pages ([\w \-]+?):\s+(\d+)", sh("vm_stat"))}
    used = (vm.get("active", 0) + vm.get("wired down", 0)
            + vm.get("occupied by compressor", 0)) * page
    return total, min(used, total)


def gpu():
    out = sh("ioreg", "-r", "-d", "1", "-c", "IOAccelerator")
    util = re.search(r'"Device Utilization %"=(\d+)', out)
    used = re.search(r'"In use system memory"=(\d+)', out)
    return (int(util.group(1)) if util else 0), (int(used.group(1)) if used else 0)


def net_bytes():
    rx = tx = 0
    seen = set()
    for line in sh("netstat", "-ib").splitlines()[1:]:
        p = line.split()
        if len(p) < 10 or not p[0].startswith("en") or p[0] in seen or "Link" not in p[2]:
            continue
        seen.add(p[0])
        rx += int(p[-5]); tx += int(p[-2])
    return rx, tx


def disk_bytes():
    out = sh("ioreg", "-r", "-c", "IOBlockStorageDriver", "-d", "1")
    r = sum(int(x) for x in re.findall(r'"Bytes \(Read\)"=(\d+)', out))
    w = sum(int(x) for x in re.findall(r'"Bytes \(Write\)"=(\d+)', out))
    return r, w


def top_procs(by_mem=False):
    rows = []
    for line in sh("ps", "-Amco" if by_mem else "-Arco", "pid,pcpu,rss,comm").splitlines()[1:9]:
        p = line.split(None, 3)
        if len(p) == 4:
            rows.append({"pid": int(p[0]), "cpu": float(p[1]), "mem": int(p[2]) * 1024, "name": p[3]})
    return rows


def uptime():
    m = re.search(r"sec = (\d+)", sysctl("kern.boottime"))
    return int(time.time() - int(m.group(1))) if m else 0


STATIC = {
    "host": os.environ.get("MACMON_HOST") or socket.gethostname().replace(".local", ""),   # MACMON_HOST hides your real hostname (screenshots, demos)
    "os": "macOS " + sh("sw_vers", "-productVersion").strip(),
    "chip": sysctl("machdep.cpu.brand_string"),
    "model": (re.search(r"Model Name: (.+)", sh("system_profiler", "SPHardwareDataType")) or [None, "Mac"])[1],
    "cores": int(sysctl("hw.ncpu")),
    "gpu_cores": (lambda m: int(m.group(1)) if m else 0)(
        re.search(r'"gpu-core-count" = (\d+)', sh("ioreg", "-r", "-d", "1", "-c", "IOAccelerator"))),
}

state = {"history": [], "now": {}}
lock = threading.Lock()


def load_history():
    try:
        with open(SAVE) as f:
            cutoff = time.time() - HISTORY
            state["history"] = [h for h in json.load(f) if h["t"] > cutoff]
    except Exception:
        pass


def save_history():
    try:
        os.makedirs(os.path.dirname(SAVE), exist_ok=True)
        with lock:
            data = json.dumps(state["history"])
        with open(SAVE + ".tmp", "w") as f:
            f.write(data)
        os.replace(SAVE + ".tmp", SAVE)
    except Exception:
        pass


def sampler():
    prev_t = cpu_ticks()
    prev_net = net_bytes()
    prev_disk = disk_bytes()
    prev_time = time.time()
    tick = 0
    procs = procs_mem = []
    while True:
        time.sleep(1)
        now = time.time()
        dt = max(now - prev_time, 0.001)
        t = cpu_ticks()
        d = [t[i] - prev_t[i] for i in range(4)]
        cpu = 100 * (d[0] + d[1] + d[3]) / max(sum(d), 1)
        n = net_bytes(); dk = disk_bytes()
        g_util, g_mem = gpu()
        total, used = memory()
        if tick % 3 == 0:
            procs = top_procs()
            procs_mem = top_procs(True)
        disk = shutil.disk_usage("/System/Volumes/Data")
        sample = {
            "t": int(now),
            "cpu": round(cpu, 1),
            "gpu": g_util,
            "mem": round(100 * used / total, 1),
            "mem_used": used, "mem_total": total,
            "gpu_mem": g_mem,
            "disk_used": disk.used, "disk_total": disk.total,
            "net_down": max(n[0] - prev_net[0], 0) / dt,
            "net_up": max(n[1] - prev_net[1], 0) / dt,
            "disk_read": max(dk[0] - prev_disk[0], 0) / dt,
            "disk_write": max(dk[1] - prev_disk[1], 0) / dt,
            "load": os.getloadavg(),
            "uptime": uptime(),
            "procs": procs,
            "procs_mem": procs_mem,
        }
        prev_t, prev_net, prev_disk, prev_time = t, n, dk, now
        tick += 1
        with lock:
            state["now"] = sample
            state["history"].append({k: sample[k] for k in ("t", "cpu", "gpu", "mem")})
            del state["history"][:-HISTORY]
        if tick % 30 == 0:
            save_history()


UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
LIVE_CACHE = {}


def live_video(channel):
    """YouTube no longer embeds a channel's live stream directly, so ask which video the channel is live on right now."""
    hit = LIVE_CACHE.get(channel)
    if hit and time.time() - hit[0] < (300 if hit[1] else 60):
        return hit[1]
    vid = None
    try:
        req = urllib.request.Request(f"https://www.youtube.com/channel/{channel}/live?hl=en",
                                     headers={"User-Agent": UA, "Accept-Language": "en-US,en;q=0.9"})
        with urllib.request.urlopen(req, timeout=8) as r:
            html = r.read(3_000_000).decode("utf-8", "ignore")
        m = re.search(r'<link rel="canonical" href="https://www\.youtube\.com/watch\?v=([\w-]{11})"', html)
        if m and '"isLive":true' in html:
            vid = m.group(1)
    except Exception:
        pass
    LIVE_CACHE[channel] = (time.time(), vid)
    return vid


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/api/stats"):
            m = re.search(r"since=(\d+)", self.path)
            since = int(m.group(1)) if m else 0
            with lock:
                hist = [h for h in state["history"] if h["t"] > since]
                body = json.dumps({"static": STATIC, "now": state["now"], "history": hist})
            self.send(body.encode(), "application/json")
        elif self.path.startswith("/api/live"):
            m = re.search(r"channel=(UC[\w-]{20,})", self.path)
            self.send(json.dumps({"id": live_video(m.group(1)) if m else None}).encode(), "application/json")
        elif self.path.startswith("/audio/"):
            parts = [p for p in self.path.split("?")[0].split("/")[2:] if p]
            name = os.path.basename(parts[-1]) if parts else ""
            sub = "fx" if len(parts) == 2 and parts[0] == "fx" else ""
            try:
                with open(os.path.join(HERE, "audio", sub, name), "rb") as f:
                    self.send(f.read(), "audio/wav" if name.endswith(".wav") else "audio/mpeg")
            except OSError:
                self.send_error(404)
        elif self.path.startswith("/vendor/"):
            name = os.path.basename(self.path.split("?")[0])
            try:
                with open(os.path.join(HERE, "vendor", name), "rb") as f:
                    self.send(f.read(), "application/javascript")
            except OSError:
                self.send_error(404)
        else:
            page = "war.html" if self.path.split("?")[0].rstrip("/") == "/war" else "index.html"
            with open(os.path.join(HERE, page), "rb") as f:
                self.send(f.read(), "text/html; charset=utf-8")


if __name__ == "__main__":
    load_history()
    import atexit, signal
    atexit.register(save_history)
    signal.signal(signal.SIGTERM, lambda *a: (save_history(), os._exit(0)))
    threading.Thread(target=sampler, daemon=True).start()
    ppid = os.getppid()

    def watch_parent():  # exit if the launching app dies, so no orphan servers
        while ppid != 1 and os.getppid() == ppid:
            time.sleep(2)
        save_history()
        os._exit(0)
    if os.environ.get("MACMON_APP"):
        threading.Thread(target=watch_parent, daemon=True).start()
    print(f"macmon running at http://localhost:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

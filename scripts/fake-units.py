#!/usr/bin/env python3
"""Pretend to be extra Prana units on this Mac, to try PranaBar with more than one.

    sudo scripts/fake-units.py                 # two units: Loft, Bedroom
    sudo scripts/fake-units.py Loft Hall Den   # one per name

Each fake unit gets its own loopback address (127.0.0.11, .12, ...), serves the
Prana HTTP API on port 80 there, and announces itself over Bonjour the way a real
unit does: `_prana._tcp`, instance name = manufactureId, host <id>.local, TXT
label= and maxSpeed=, advertised port 12345 (which, as on a real unit, nothing
listens on). So PranaBar finds and talks to them with its normal code.

Root is needed for the loopback aliases and port 80. Ctrl-C removes everything.

State is in memory and resets when the script stops. Writes behave like the
office unit (fw 49) where we know how it behaves: speed is written x10, brightness
as 0/1/2/4/8/16/32, every command answers {"result":"ok"}, bound=true is ignored
while Auto+ is on, and turning Auto+ on unlinks the fans. Readings drift a little
so the popover has something to show.
"""

import hashlib
import json
import os
import random
import signal
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BRIGHTNESS_RAW = [0, 1, 2, 4, 8, 16, 32]
FIRST_HOST = 11  # 127.0.0.11 onwards; .1 is left alone


class FakeUnit:
    def __init__(self, name, address):
        self.name = name
        self.address = address
        self.device_id = "FA" + hashlib.sha1(name.encode()).hexdigest()[:10].upper()
        self.lock = threading.Lock()
        rng = random.Random(name)
        self.state = {
            "extract": {"speed": 2, "is_on": True, "max_speed": 60},
            "supply": {"speed": 2, "is_on": True, "max_speed": 60},
            "bounded": {"speed": 2, "is_on": True, "max_speed": 60},
            "bound": True,
            "heater": False,
            "auto": False,
            "auto_plus": False,
            "night": False,
            "boost": False,
            "winter": False,
            "inside_temperature": rng.randint(190, 240),
            "outside_temperature_2": rng.randint(50, 150),
            "humidity": rng.randint(35, 60),
            "air_pressure": 728,
            "brightness": 3,
        }

    def info(self):
        return {
            "manufactureId": self.device_id,
            "isValid": True,
            "fwVersion": 49,
            "pranaModel": 2,
            "pranaSubtype": 0,
            "label": self.name.ljust(17),  # the real unit pads with spaces
        }

    def read(self):
        with self.lock:
            s = self.state
            s["inside_temperature"] += random.choice([-1, 0, 0, 1])
            s["humidity"] = max(20, min(80, s["humidity"] + random.choice([-1, 0, 0, 0, 1])))
            return json.loads(json.dumps(s))

    def command(self, path, body):
        with self.lock:
            s = self.state
            if path == "/setSpeed":
                level = max(1, min(6, int(body["speed"]) // 10))
                fans = ["bounded", "supply", "extract"] if body["fanType"] == "bounded" else [body["fanType"]]
                for fan in fans:
                    s[fan]["speed"] = level
            elif path == "/setSpeedIsOn":
                fans = ["bounded", "supply", "extract"] if body["fanType"] == "bounded" else [body["fanType"]]
                for fan in fans:
                    s[fan]["is_on"] = bool(body["value"])
            elif path == "/setSwitch":
                key, value = body["switchType"], bool(body["value"])
                if key == "bound" and value and s["auto_plus"]:
                    pass  # ignored, but still "ok"
                elif key in s:
                    s[key] = value
                    if key == "auto_plus" and value:
                        s["bound"] = False
            elif path == "/setBrightness":
                raw = int(body["brightness"])
                s["brightness"] = BRIGHTNESS_RAW.index(raw) if raw in BRIGHTNESS_RAW else 3
            else:
                return False
            return True


def handler_for(unit):
    class Handler(BaseHTTPRequestHandler):
        def _reply(self, code, payload):
            data = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/getState":
                self._reply(200, unit.read())
            elif self.path == "/info":
                self._reply(200, unit.info())
            else:
                self._reply(404, {"error": "not found"})

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
                ok = unit.command(self.path, body)
            except (ValueError, KeyError, TypeError):
                self._reply(400, {"result": "error"})
                return
            if ok:
                print(f"  {unit.name}: {self.path} {json.dumps(body)}")
                self._reply(200, {"result": "ok"})
            else:
                self._reply(404, {"error": "not found"})

        def log_message(self, *args):
            pass  # reads every 3 s would drown out the commands

    return Handler


def main():
    if os.geteuid() != 0:
        sys.exit("Run with sudo: it adds loopback addresses and serves on port 80.")
    names = sys.argv[1:] or ["Loft", "Bedroom"]
    units = [FakeUnit(n, f"127.0.0.{FIRST_HOST + i}") for i, n in enumerate(names)]

    servers, adverts, aliases = [], [], []

    def cleanup(*_):
        for p in adverts:
            p.terminate()
        for s in servers:
            threading.Thread(target=s.shutdown, daemon=True).start()
        for a in aliases:
            subprocess.run(["ifconfig", "lo0", "-alias", a], check=False)
        print("\nStopped; loopback addresses removed.")
        os._exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    try:
        for unit in units:
            subprocess.run(["ifconfig", "lo0", "alias", unit.address], check=True)
            aliases.append(unit.address)
            server = ThreadingHTTPServer((unit.address, 80), handler_for(unit))
            servers.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            adverts.append(subprocess.Popen(
                ["dns-sd", "-P", unit.device_id, "_prana._tcp", "local", "12345",
                 f"{unit.device_id}.local", unit.address,
                 f"label={unit.name.ljust(17)}", "maxSpeed=60"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            print(f"{unit.name:<10} {unit.device_id}  http://{unit.address}/getState")
    except Exception as e:
        print(f"Couldn't start: {e}")
        cleanup()

    print("Commands from PranaBar show below. Ctrl-C to stop.")
    signal.pause()


if __name__ == "__main__":
    main()

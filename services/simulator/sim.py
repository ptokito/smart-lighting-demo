"""
simulator: generates steady, realistic load for the demo.

Where it runs
    In Kubernetes (k3s), 1 replica. It has no New Relic agent on purpose: it
    plays the part of the outside world (devices in the field and people using
    the portal), and the traffic it generates is what we observe.

Two loops, each in its own thread:

1. Devices: all 60 streetlights and signals check in to device-gateway on the
   host VM every 30 seconds with their power draw and lamp health. Two
   streetlights have a permanently failed lamp so the dashboards always show
   a realistic, non-zero fault count.

2. Operators and residents: every 1 to 3 seconds, one action through the
   public path (NGINX on the host VM, then the portal), weighted like real use:
     35%  load the operations page and its summary
     25%  list devices
     25%  send a command (streetlights: on / dim; signals: flash / normal)
     10%  open a device's 7-day history (the slow-query candidate)
      5%  resident outage report (1 in 10 has a mistyped pole number -> 404)

Going through NGINX rather than calling services directly means the NGINX
integration, the portal, and every hop after it see the traffic, exactly as
they would for a real user.
"""

import logging
import os
import random
import threading
import time

import requests

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s simulator %(message)s")
log = logging.getLogger("simulator")

GATEWAY_URL = os.environ["GATEWAY_URL"]      # http://<host VM IP>:8081
PUBLIC_URL = os.environ["PUBLIC_URL"]        # http://<host VM IP> (NGINX)

DISTRICTS = ["RV", "OM", "CS", "CH"]
STREETLIGHTS = [f"SL-{d}-{n:03d}" for d in DISTRICTS for n in range(1, 13)]
SIGNALS = [f"TS-{d}-{n:03d}" for d in DISTRICTS for n in range(1, 4)]
DEVICES = STREETLIGHTS + SIGNALS
BROKEN_LAMPS = {"SL-OM-004", "SL-CH-009"}    # always report a lamp fault

session = requests.Session()


def device_loop():
    """Every 30 seconds, every device sends a heartbeat to the gateway."""
    while True:
        cycle_start = time.time()
        for device_id in DEVICES:
            is_signal = device_id.startswith("TS")
            payload = {
                "device_id": device_id,
                "power_w": round(random.uniform(90, 120) if is_signal else random.uniform(45, 60), 1),
                "lamp_ok": device_id not in BROKEN_LAMPS,
            }
            try:
                session.post(f"{GATEWAY_URL}/checkin", json=payload, timeout=5)
            except requests.RequestException as exc:
                log.warning("check-in failed device=%s error=%s", device_id, exc)
            time.sleep(0.2)   # spread 60 check-ins across about 12 seconds
        time.sleep(max(0, 30 - (time.time() - cycle_start)))


def one_user_action():
    """Perform one randomly chosen portal action, weighted like real use."""
    roll = random.random()
    if roll < 0.35:
        session.get(f"{PUBLIC_URL}/", timeout=20)
        session.get(f"{PUBLIC_URL}/api/summary", timeout=20)
    elif roll < 0.60:
        session.get(f"{PUBLIC_URL}/api/devices", timeout=20)
    elif roll < 0.85:
        device_id = random.choice(DEVICES)
        command = random.choice(["flash", "normal"] if device_id.startswith("TS") else ["on", "dim:50", "off"])
        session.post(f"{PUBLIC_URL}/api/commands", json={"device_id": device_id, "command": command,
                                                         "source": "schedule"}, timeout=20)
    elif roll < 0.95:
        session.get(f"{PUBLIC_URL}/api/devices/{random.choice(DEVICES)}/history", timeout=30)
    else:
        # 1 in 10 resident reports carries a mistyped pole number (expected 404).
        device_id = random.choice(DEVICES) if random.random() > 0.1 else "SL-XX-999"
        session.post(f"{PUBLIC_URL}/api/reports", json={"device_id": device_id,
                                                        "description": "Light out near the bus stop",
                                                        "source": "resident"}, timeout=20)


def user_loop(worker: int):
    """Run portal actions forever with a short random pause between them."""
    while True:
        try:
            one_user_action()
        except requests.RequestException as exc:
            log.warning("user action failed worker=%d error=%s", worker, exc)
        time.sleep(random.uniform(1, 3))


if __name__ == "__main__":
    log.info("starting: %d devices, gateway=%s public=%s", len(DEVICES), GATEWAY_URL, PUBLIC_URL)
    threading.Thread(target=device_loop, daemon=True).start()
    # Two user workers so one slow request (a long command) does not stall all traffic.
    for i in range(2):
        threading.Thread(target=user_loop, args=(i,), daemon=True).start()
    while True:
        time.sleep(3600)

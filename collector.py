#!/usr/bin/env python3
"""Read-only Linux telemetry. One JSON line every two seconds; no pip dependencies."""
import argparse
from functools import lru_cache
import ipaddress
import json
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import threading
import time
import tomllib
import urllib.request


def read(path):
    try:
        return Path(path).read_text().strip()
    except (OSError, UnicodeError):
        return ""


def number(path, scale=1):
    try:
        return float(read(path)) / scale
    except ValueError:
        return None


def cpu_ticks(raw):
    result = {}
    for line in raw.splitlines():
        fields = line.split()
        if fields and re.fullmatch(r"cpu\d*", fields[0]) and len(fields) >= 5:
            values = [int(v) for v in fields[1:9]]  # guest already included in user/nice
            result[fields[0]] = (sum(values), values[3] + (values[4] if len(values) > 4 else 0))
    return result


def cpu_percent(current, previous):
    result = {}
    for key, (total, idle) in current.items():
        old = previous.get(key)
        dt = total - old[0] if old else 0
        result[key] = round(max(0, min(100, 100 * (dt - (idle - old[1])) / dt)), 1) if dt > 0 else None
    return result


def memory(raw):
    fields = {}
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            fields[parts[0].rstrip(":")] = int(parts[1]) * 1024
    total = fields.get("MemTotal", 0)
    available = fields.get("MemAvailable")
    if not total or available is None:
        return {"percent": None, "used": None, "total": total or None}
    used = max(0, total - available)
    return {"percent": round(100 * used / total, 1), "used": used, "total": total}


def disk_counters(raw, sys):
    counters = {}
    for line in raw.splitlines():
        fields = line.split()
        if len(fields) < 14 or not (sys / "block" / fields[2] / "device").exists():
            continue  # Whole hardware devices only; avoid partition/mapper double counting.
        try:
            counters[fields[2]] = (int(fields[5]) * 512, int(fields[9]) * 512)
        except ValueError:
            continue
    return counters


@lru_cache(maxsize=8)
def disk_models(names):
    # sysfs truncates models to 16 characters; lsblk reads the full name from udev.
    models = {name: read(Path("/sys/block") / name / "device/model") for name in names}
    try:
        output = subprocess.run(["lsblk", "-d", "-J", "-o", "NAME,MODEL"], capture_output=True, text=True, timeout=1, check=True).stdout
        for device in json.loads(output).get("blockdevices", []):
            if device.get("name") in models and device.get("model"):
                models[device["name"]] = device["model"].strip()
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return models


def mount_points(raw):
    """One mount per real block device (first/shortest path wins), skipping boot partitions."""
    seen = {}
    for line in raw.splitlines():
        fields = line.split()
        if len(fields) < 3 or not fields[0].startswith("/dev/"):
            continue
        source, path = fields[0], fields[1].replace("\\040", " ")
        if path in ("/boot", "/efi", "/boot/efi") or path.startswith("/snap/"):
            continue
        if source not in seen or len(path) < len(seen[source]):
            seen[source] = path
    return sorted(seen.values(), key=lambda p: (p != "/", p))


def mount_usage(paths):
    mounts = []
    for path in paths:
        try:
            capacity = shutil.disk_usage(path)
        except OSError:
            continue
        if not capacity.total:
            continue
        label = "SYS" if path == "/" else Path(path).name or path
        mounts.append({"path": path, "label": label, "total": capacity.total, "used": capacity.used,
                       "free": capacity.free, "percent": round(100 * capacity.used / capacity.total, 1)})
    return mounts


def disk_sample(current, previous, elapsed, models=None):
    models = models or {}
    result = {"path": "/", "percent": None, "used": None, "total": None,
              "free": None, "readRate": None, "writeRate": None,
              "devices": [{"name": k, "model": models.get(k, ""), "readRate": None, "writeRate": None} for k in sorted(current)]}
    try:
        capacity = shutil.disk_usage("/")
        result.update(total=capacity.total, used=capacity.used, free=capacity.free,
                      percent=round(100 * capacity.used / capacity.total, 1) if capacity.total else None)
    except OSError:
        pass
    common = current.keys() & previous.keys()
    if common and elapsed > 0:
        deltas = [(current[k][0] - previous[k][0], current[k][1] - previous[k][1]) for k in common]
        if all(r >= 0 and w >= 0 for r, w in deltas):
            result.update(readRate=sum(r for r, _ in deltas) / elapsed,
                          writeRate=sum(w for _, w in deltas) / elapsed)
        for device in result["devices"]:
            old, new = previous.get(device["name"]), current[device["name"]]
            if old and new[0] >= old[0] and new[1] >= old[1]:
                device.update(readRate=(new[0] - old[0]) / elapsed, writeRate=(new[1] - old[1]) / elapsed)
    return result


def net_counters(raw, sys):
    counters = {}
    for line in raw.splitlines():
        name, sep, rest = line.partition(":")
        name, fields = name.strip(), rest.split()
        if not sep or len(fields) < 9 or not (sys / "class/net" / name / "device").exists():
            continue  # Physical NICs only: tunnels and bridges would count the same bytes twice.
        try:
            counters[name] = (int(fields[0]), int(fields[8]))
        except ValueError:
            continue
    return counters


def net_sample(current, previous, elapsed):
    result = {"rxRate": None, "txRate": None, "interfaces": sorted(current)}
    common = current.keys() & previous.keys()
    if common and elapsed > 0:
        deltas = [(current[k][0] - previous[k][0], current[k][1] - previous[k][1]) for k in common]
        if all(rx >= 0 and tx >= 0 for rx, tx in deltas):
            result.update(rxRate=sum(rx for rx, _ in deltas) / elapsed,
                          txRate=sum(tx for _, tx in deltas) / elapsed)
    return result


VPN_KINDS = (("zt", "zerotier"), ("tailscale", "tailscale"), ("wg", "wireguard"), ("tun", "vpn"), ("tap", "vpn"), ("ppp", "vpn"))


def vpn_kind(name):
    return next((kind for prefix, kind in VPN_KINDS if name.startswith(prefix)), None)


def vpn_links(addresses):
    # A tunnel counts as connected once it is up and holds an address; ZeroTier
    # reports operstate "unknown", so the UP flag is the reliable signal.
    result = []
    for link in addresses:
        name = link.get("ifname", "")
        kind = vpn_kind(name)
        ips = [a.get("local") for a in link.get("addr_info", []) if a.get("family") == "inet" and a.get("local")]
        if kind and "UP" in link.get("flags", []) and ips:
            result.append({"name": name, "kind": kind, "addresses": ips})
    return result


def ip_addresses():
    try:
        output = subprocess.run(["ip", "-j", "-4", "addr"], capture_output=True, text=True, timeout=1, check=True).stdout
        return json.loads(output)
    except (OSError, subprocess.SubprocessError, ValueError):
        return []


PUBLIC_IP_URL = "https://api.ipify.org"


class PublicIp:
    """Looks up the public address off the sampling thread, every few minutes or when tunnels change."""

    def __init__(self, interval=300):
        self.interval, self.value, self.checked, self.key = interval, None, 0.0, None
        self.lock, self.busy = threading.Lock(), False

    def fetch(self):
        try:
            with urllib.request.urlopen(PUBLIC_IP_URL, timeout=5) as response:
                text = response.read(64).decode().strip()
            value = str(ipaddress.ip_address(text))
        except (OSError, ValueError):
            value = None
        with self.lock:
            self.value, self.busy = value, False

    def get(self, key):
        with self.lock:
            due = time.monotonic() - self.checked >= self.interval or key != self.key or (self.value is None and time.monotonic() - self.checked >= 30)
            if due and not self.busy:
                self.checked, self.key, self.busy = time.monotonic(), key, True
                threading.Thread(target=self.fetch, daemon=True).start()
            return self.value


def sensors(root):
    result = []
    for hw in sorted(root.glob("class/hwmon/hwmon*")):
        name = read(hw / "name")
        for path in sorted(hw.glob("temp*_input")):
            value = number(path, 1000)
            if value is not None and -20 <= value <= 150:
                label = read(path.with_name(path.name.replace("_input", "_label"))) or name
                result.append({"driver": name, "label": label, "value": value})
    return result


def cpu_model(raw):
    fields = dict(line.split(":", 1) for line in raw.splitlines() if ":" in line)
    fields = {key.strip(): value.strip() for key, value in fields.items()}
    return fields.get("model name") or fields.get("Hardware") or fields.get("Processor") or ""


@lru_cache(maxsize=32)
def gpu_model(address, vendor, device, revision):
    # AMD's revision-specific database identifies the product more precisely
    # than the PCI family name. Cache static identity, never live telemetry.
    if vendor == "0x1002":
        for line in read("/usr/share/libdrm/amdgpu.ids").splitlines():
            parts = [part.strip() for part in line.split(",", 2)]
            if len(parts) == 3 and parts[0].lower() == device.removeprefix("0x").lower() and parts[1].lower() == revision.removeprefix("0x").lower():
                return parts[2]
    if re.fullmatch(r"[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]", address):
        try:
            output = subprocess.run(["lspci", "-D", "-mm", "-s", address], capture_output=True, text=True, timeout=1, check=True).stdout
            parts = shlex.split(output)
            if len(parts) >= 4:
                return parts[3]
        except (OSError, subprocess.SubprocessError, ValueError):
            pass
    return {"0x1002": "AMD Radeon GPU", "0x10de": "NVIDIA GPU", "0x8086": "Intel GPU"}.get(vendor, "GPU")


def gpu_sysfs(root):
    gpus = []
    for card in sorted(root.glob("class/drm/card*")):
        if not re.fullmatch(r"card\d+", card.name):
            continue
        device = card / "device"
        vendor = read(device / "vendor")
        if not vendor:
            continue
        hw = next(iter(sorted(device.glob("hwmon/hwmon*"))), None)
        temps = {}
        if hw:
            for p in sorted(hw.glob("temp*_input")):
                label = read(p.with_name(p.name.replace("_input", "_label"))).lower()
                temps[label or "edge"] = number(p, 1000)
        total = number(device / "mem_info_vram_total")
        used = number(device / "mem_info_vram_used")
        gpus.append({"id": card.name, "vendor": vendor, "name": gpu_model(device.resolve().name, vendor, read(device / "device"), read(device / "revision")),
                     "percent": number(device / "gpu_busy_percent"), "total": total, "used": used,
                     "temperature": temps.get("edge"), "hotspot": temps.get("junction"),
                     "power": number(hw / "power1_average", 1e6) if hw else None,
                     "fan": number(hw / "fan1_input") if hw else None})
    return gpus


def nvidia():
    if not shutil.which("nvidia-smi"):
        return []
    try:
        output = subprocess.run(["nvidia-smi", "--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw", "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=1.2, check=True).stdout
        result = []
        for row in output.splitlines():
            parts = [p.strip() for p in row.split(",")]
            if len(parts) != 7:
                continue
            def val(i, scale=1):
                try:
                    return float(parts[i]) * scale
                except ValueError:
                    return None
            result.append({"id": "nvidia-" + parts[0], "name": parts[1], "percent": val(2), "used": val(3, 1048576), "total": val(4, 1048576), "temperature": val(5), "power": val(6), "fan": None, "hotspot": None})
        return result
    except (OSError, subprocess.SubprocessError):
        return []


def palette():
    # Theme swaps replace a directory/symlink: reopen instead of watching its old inode.
    home = Path.home()
    candidates = [home / ".local/state/omarchy/current/theme/colors.toml", home / ".config/omarchy/current/theme/colors.toml"]
    for path in candidates:
        try:
            colors = tomllib.loads(path.read_text())
            return {k: v for k, v in colors.items() if isinstance(v, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", v)}
        except (OSError, ValueError):
            continue
    return {}


class Collector:
    def __init__(self, proc=Path("/proc"), sys=Path("/sys"), use_nvidia=True):
        self.proc, self.sys = proc, sys
        self.previous = {}
        self.cpu_model = cpu_model(read(proc / "cpuinfo"))
        self.use_nvidia = use_nvidia
        self.disk_previous = {}
        self.disk_time = time.monotonic()
        self.net_previous = {}
        self.net_time = time.monotonic()
        self.public_ip = PublicIp()

    def sample(self):
        disk_now = time.monotonic()
        counters = disk_counters(read(self.proc / "diskstats"), self.sys)
        disk = disk_sample(counters, self.disk_previous, disk_now - self.disk_time, disk_models(tuple(sorted(counters))))
        disk["mounts"] = mount_usage(mount_points(read(self.proc / "mounts")))
        self.disk_previous, self.disk_time = counters, disk_now
        net_now = time.monotonic()
        net_counts = net_counters(read(self.proc / "net/dev"), self.sys)
        net = net_sample(net_counts, self.net_previous, net_now - self.net_time)
        self.net_previous, self.net_time = net_counts, net_now
        vpn = vpn_links(ip_addresses())
        net["publicIp"] = self.public_ip.get(tuple(v["name"] for v in vpn))
        net["vpn"] = vpn
        ticks = cpu_ticks(read(self.proc / "stat"))
        loads = cpu_percent(ticks, self.previous)
        self.previous = ticks
        temperatures = sensors(self.sys)
        cpu_temps = [t["value"] for t in temperatures if t["driver"] in ("coretemp", "k10temp", "zenpower", "cpu_thermal")]
        gpus = gpu_sysfs(self.sys)
        nv = nvidia() if self.use_nvidia and any(g.get("vendor") == "0x10de" for g in gpus) else []
        if nv:
            gpus = [g for g in gpus if g.get("vendor") != "0x10de"] + nv
        # Prefer a GPU with utilization telemetry, while retaining all adapters in the payload.
        gpu = next((g for g in gpus if g["percent"] is not None), gpus[0] if gpus else {})
        return {"time": time.time(), "cpu": loads.get("cpu"), "cores": [loads[k] for k in sorted(loads, key=lambda k: int(k[3:] or -1)) if k != "cpu"],
                "cpuModel": self.cpu_model, "cpuTemperature": max(cpu_temps) if cpu_temps else None,
                "disk": disk, "net": net, "memory": memory(read(self.proc / "meminfo")), "gpu": gpu, "gpus": gpus, "palette": palette(),
                "error": "Cannot read /proc CPU or memory data" if not ticks or not read(self.proc / "meminfo") else ""}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--interval", type=int, choices=(1, 2, 5), default=2)
    args = parser.parse_args()
    collector = Collector()
    if args.once:
        collector.sample()
        time.sleep(0.15)
    while True:
        start = time.monotonic()
        print(json.dumps(collector.sample(), allow_nan=False), flush=True)
        if args.once:
            return
        time.sleep(max(0.1, args.interval - (time.monotonic() - start)))


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass

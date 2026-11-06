#!/usr/bin/env python3
"""
ui/jetson_telemetry.py
======================
Hardware telemetry module for NVIDIA Jetson Orin Nano Super.
Reads real-time stats via jetson-stats (jtop) with primary high-accuracy fallback
to tegrastats daemon / direct sysfs / IIO power monitors and /proc interfaces.

Exposes:
  - TelemetryCollector: async-friendly class with background sampling and get_snapshot()
  - Structured JSON telemetry dict
"""

import os
import re
import sys
import time
import shutil
import logging
import asyncio
import threading
import subprocess
from typing import Dict, Any, Optional

logger = logging.getLogger("jetson_telemetry")

try:
    from jtop import jtop, JtopException
    HAS_JTOP = True
except ImportError:
    HAS_JTOP = False
    logger.warning("jetson-stats (jtop) not installed. Using tegrastats / kernel telemetry.")


class TegrastatsReader:
    """Spawns and monitors a background tegrastats process to parse real-time GPU and power."""

    def __init__(self, interval_ms: int = 500):
        self.interval_ms = interval_ms
        self._proc: Optional[subprocess.Popen] = None
        self._thread: Optional[threading.Thread] = None
        self._running = False
        self.latest_stats: Dict[str, Any] = {
            "gr3d_percent": 0.0,
            "emc_percent": 0.0,
            "power_watts": 0.0,
            "thermals": {},
            "ram_used_mb": 0.0,
            "ram_total_mb": 0.0,
            "raw_line": "",
        }
        self._lock = threading.Lock()

    def start(self):
        tegrastats_bin = shutil.which("tegrastats") or "/usr/bin/tegrastats"
        if not os.path.exists(tegrastats_bin):
            logger.warning("tegrastats binary not found on system.")
            return

        self._running = True
        try:
            self._proc = subprocess.Popen(
                [tegrastats_bin, "--interval", str(self.interval_ms)],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                universal_newlines=True,
                bufsize=1,
            )
            self._thread = threading.Thread(target=self._reader_loop, daemon=True)
            self._thread.start()
            logger.info("tegrastats background reader started.")
        except Exception as e:
            logger.warning(f"Failed to start tegrastats: {e}")
            self._running = False

    def _reader_loop(self):
        if not self._proc or not self._proc.stdout:
            return
        while self._running:
            line = self._proc.stdout.readline()
            if not line:
                break
            self._parse_line(line.strip())

    def _parse_line(self, line: str):
        if not line:
            return
        stats: Dict[str, Any] = {"raw_line": line}

        # GR3D_FREQ (e.g. GR3D_FREQ 35% or GR3D_FREQ 35%@114 or GR3D_FREQ @[314,314])
        gr3d_m = re.search(r"GR3D_FREQ\s+(\d+)%", line)
        if gr3d_m:
            stats["gr3d_percent"] = float(gr3d_m.group(1))

        # EMC_FREQ (e.g. EMC_FREQ 12% or EMC_FREQ 12%@2133)
        emc_m = re.search(r"EMC_FREQ\s+(\d+)%", line)
        if emc_m:
            stats["emc_percent"] = float(emc_m.group(1))

        # RAM (e.g. RAM 3512/7665MB)
        ram_m = re.search(r"RAM\s+(\d+)/(\d+)MB", line)
        if ram_m:
            stats["ram_used_mb"] = float(ram_m.group(1))
            stats["ram_total_mb"] = float(ram_m.group(2))

        # Power rails (e.g. VDD_IN 6123mW/6123mW, POM_5V_IN 5432mW, VIN_SYS_5V0 5200mW, VDD_GPU_SOC 1200mW)
        # Sum main or input rail
        power_mw = 0.0
        # Priority 1: VDD_IN or VIN_SYS_5V0 or POM_5V_IN (overall board input)
        main_rail_m = re.search(r"(?:VDD_IN|POM_5V_IN|VIN_SYS_5V0|VIN)\s+(\d+)mW", line)
        if main_rail_m:
            power_mw = float(main_rail_m.group(1))
        else:
            # Sum all detected VDD rails
            vdd_rails = re.findall(r"VDD_\w+\s+(\d+)mW", line)
            if vdd_rails:
                power_mw = sum(float(v) for v in vdd_rails)

        stats["power_watts"] = round(power_mw / 1000.0, 2)

        # Thermal probes in line: CPU@52C, GPU@49C, AO@47C, soc0@...
        thermals = {}
        for tm in re.finditer(r"([A-Za-z0-9_]+)@([0-9.]+)C", line):
            k = tm.group(1).lower()
            v = float(tm.group(2))
            if "cpu" in k:
                thermals["cpu_c"] = v
            elif "gpu" in k:
                thermals["gpu_c"] = v
            elif "ao" in k or "soc" in k or "tj" in k:
                thermals["ao_c"] = v
        stats["thermals"] = thermals

        with self._lock:
            self.latest_stats.update(stats)

    def get_stats(self) -> Dict[str, Any]:
        with self._lock:
            return dict(self.latest_stats)

    def stop(self):
        self._running = False
        if self._proc:
            try:
                self._proc.terminate()
                self._proc.wait(timeout=1.0)
            except Exception:
                try:
                    self._proc.kill()
                except Exception:
                    pass
            self._proc = None


class TelemetryCollector:
    """Collects real-time Jetson system metrics at configurable intervals."""

    def __init__(self, sample_interval: float = 0.5):
        self.sample_interval = sample_interval
        self._jtop_instance: Optional[Any] = None
        self._jtop_active = False
        self._tegrastats = TegrastatsReader(interval_ms=int(sample_interval * 1000))
        self._last_cpu_times: Dict[str, tuple] = {}
        self._cached_snapshot: Dict[str, Any] = {}
        self._running = False

    def start(self):
        """Initialize telemetry services (jtop and background tegrastats parser)."""
        if HAS_JTOP:
            try:
                self._jtop_instance = jtop()
                self._jtop_instance.start()
                if self._jtop_instance.ok():
                    self._jtop_active = True
                    logger.info("jtop telemetry service connected successfully.")
            except Exception as e:
                logger.warning(f"Could not initialize jtop: {e}. Starting tegrastats background parser.")
                self._jtop_active = False
                self._jtop_instance = None

        # Always start tegrastats reader as primary/fallback high-fidelity provider
        self._tegrastats.start()
        self._running = True
        self._cached_snapshot = self._collect_now()

    def stop(self):
        """Stop background sampling and close telemetry workers."""
        self._running = False
        self._tegrastats.stop()
        if self._jtop_instance and self._jtop_active:
            try:
                self._jtop_instance.close()
            except Exception:
                pass
            self._jtop_active = False
            self._jtop_instance = None

    def get_snapshot(self) -> Dict[str, Any]:
        """Return the most recent telemetry snapshot."""
        return self._collect_now()

    def _collect_now(self) -> Dict[str, Any]:
        """Collect current system metrics."""
        ts = time.time()

        if self._jtop_active and self._jtop_instance and self._jtop_instance.ok():
            try:
                snapshot = self._collect_jtop(ts)
                # If jtop returned 0 for GPU or power due to missing root hooks, patch from tegrastats
                if snapshot["gpu"]["gr3d_percent"] == 0.0 or snapshot["power"]["watts"] == 0.0:
                    tegra = self._tegrastats.get_stats()
                    if tegra.get("gr3d_percent", 0.0) > 0.0:
                        snapshot["gpu"]["gr3d_percent"] = tegra["gr3d_percent"]
                    if tegra.get("power_watts", 0.0) > 0.0:
                        snapshot["power"]["watts"] = tegra["power_watts"]
                return snapshot
            except Exception as e:
                logger.debug(f"jtop read error: {e}, falling back to tegrastats/kernel")

        return self._collect_fallback(ts)

    def _collect_jtop(self, ts: float) -> Dict[str, Any]:
        stats = self._jtop_instance.stats

        # CPU
        cpu_cores = {}
        cpu_total = 0.0
        core_count = 0
        for k, v in stats.items():
            if k.startswith("CPU") and isinstance(v, (int, float)):
                cpu_cores[k] = float(v)
                cpu_total += float(v)
                core_count += 1
            elif k.startswith("CPU") and isinstance(v, dict):
                val = v.get("val", 0)
                cpu_cores[k] = float(val)
                cpu_total += float(val)
                core_count += 1

        cpu_avg = (cpu_total / core_count) if core_count > 0 else 0.0

        # GPU
        gpu_val = stats.get("GPU", 0)
        if isinstance(gpu_val, dict):
            gpu_val = gpu_val.get("val", 0)
        gpu_load = float(gpu_val) if isinstance(gpu_val, (int, float)) else 0.0

        emc_val = stats.get("EMC", 0)
        if isinstance(emc_val, dict):
            emc_val = emc_val.get("val", 0)
        emc_load = float(emc_val) if isinstance(emc_val, (int, float)) else 0.0

        # RAM & Swap
        ram = stats.get("RAM", {})
        ram_used_mb = float(ram.get("use", 0)) / 1024.0 if isinstance(ram, dict) else 0.0
        ram_total_mb = float(ram.get("tot", 8192 * 1024)) / 1024.0 if isinstance(ram, dict) else 7800.0

        meminfo = self._read_proc_meminfo()
        mem_avail_mb = meminfo.get("MemAvailable", (ram_total_mb - ram_used_mb) * 1024) / 1024.0

        swap = stats.get("SWAP", {})
        swap_used_mb = float(swap.get("use", 0)) / 1024.0 if isinstance(swap, dict) else 0.0
        swap_total_mb = float(swap.get("tot", 0)) / 1024.0 if isinstance(swap, dict) else 0.0

        # Thermals
        temps = stats.get("temperature", {})
        temp_cpu = temps.get("CPU", temps.get("cpu", 0.0))
        temp_gpu = temps.get("GPU", temps.get("gpu", 0.0))
        temp_ao = temps.get("AO", temps.get("ao", temps.get("soc0", 0.0)))

        # Power
        power = stats.get("power", {})
        power_mw = 0.0
        if isinstance(power, dict):
            tot = power.get("tot", power.get("POM_5V_IN", {}))
            if isinstance(tot, dict):
                power_mw = float(tot.get("avg", tot.get("cur", 0)))
            elif isinstance(tot, (int, float)):
                power_mw = float(tot)
            else:
                for pk, pv in power.items():
                    if isinstance(pv, dict) and "cur" in pv:
                        power_mw += float(pv.get("cur", 0))

        power_w = power_mw / 1000.0 if power_mw > 100 else power_mw

        # Power mode
        nvp = stats.get("nvpmodel", {})
        mode_name = nvp.get("name", "MAXN_SUPER") if isinstance(nvp, dict) else "MAXN_SUPER"

        return {
            "timestamp": ts,
            "source": "jtop",
            "device": "NVIDIA Jetson Orin Nano Super",
            "cpu": {
                "overall_percent": round(cpu_avg, 1),
                "cores": cpu_cores,
            },
            "gpu": {
                "gr3d_percent": round(gpu_load, 1),
                "emc_percent": round(emc_load, 1),
            },
            "memory": {
                "used_mb": round(ram_used_mb, 1),
                "available_mb": round(mem_avail_mb, 1),
                "total_mb": round(ram_total_mb, 1),
                "percent_used": round((ram_used_mb / max(ram_total_mb, 1)) * 100, 1),
                "swap_used_mb": round(swap_used_mb, 1),
                "swap_total_mb": round(swap_total_mb, 1),
                "swap_healthy": (swap_used_mb < 50.0),
            },
            "thermal": {
                "cpu_c": round(float(temp_cpu or 0.0), 1),
                "gpu_c": round(float(temp_gpu or 0.0), 1),
                "ao_c": round(float(temp_ao or 0.0), 1),
            },
            "power": {
                "watts": round(power_w, 2),
                "mode": mode_name,
            },
        }

    def _collect_fallback(self, ts: float) -> Dict[str, Any]:
        """Tegrastats + procfs fallback."""
        tegra = self._tegrastats.get_stats()

        meminfo = self._read_proc_meminfo()
        total_kb = meminfo.get("MemTotal", 7665092)
        avail_kb = meminfo.get("MemAvailable", 3500000)
        swap_tot_kb = meminfo.get("SwapTotal", 8388604)
        swap_free_kb = meminfo.get("SwapFree", 8388604)
        swap_used_kb = swap_tot_kb - swap_free_kb

        ram_total_mb = total_kb / 1024.0
        ram_avail_mb = avail_kb / 1024.0
        ram_used_mb = (total_kb - avail_kb) / 1024.0
        swap_used_mb = swap_used_kb / 1024.0
        swap_total_mb = swap_tot_kb / 1024.0

        # CPU usage
        cpu_usage = self._read_proc_stat_cpu()

        # Thermals (tegrastats or sysfs)
        thermals = tegra.get("thermals") or self._read_thermal_zones()

        # GPU load (tegrastats or devfreq)
        gpu_load = tegra.get("gr3d_percent", 0.0)
        if gpu_load == 0.0:
            gpu_load = self._read_sysfs_gpu_load()

        emc_load = tegra.get("emc_percent", 0.0)
        power_w = tegra.get("power_watts", 0.0)
        if power_w == 0.0:
            power_w = self._read_iio_power_watts()

        return {
            "timestamp": ts,
            "source": "tegrastats+procfs",
            "device": "NVIDIA Jetson Orin Nano Super",
            "cpu": cpu_usage,
            "gpu": {
                "gr3d_percent": round(gpu_load, 1),
                "emc_percent": round(emc_load, 1),
            },
            "memory": {
                "used_mb": round(ram_used_mb, 1),
                "available_mb": round(ram_avail_mb, 1),
                "total_mb": round(ram_total_mb, 1),
                "percent_used": round((ram_used_mb / max(ram_total_mb, 1)) * 100, 1),
                "swap_used_mb": round(swap_used_mb, 1),
                "swap_total_mb": round(swap_total_mb, 1),
                "swap_healthy": (swap_used_mb < 50.0),
            },
            "thermal": thermals,
            "power": {
                "watts": round(power_w, 2),
                "mode": "MAXN_SUPER",
            },
        }

    def _read_proc_meminfo(self) -> Dict[str, int]:
        mem = {}
        try:
            with open("/proc/meminfo", "r") as f:
                for line in f:
                    parts = line.split(":")
                    if len(parts) == 2:
                        key = parts[0].strip()
                        val = int(parts[1].split()[0].strip())
                        mem[key] = val
        except Exception:
            pass
        return mem

    def _read_proc_stat_cpu(self) -> Dict[str, Any]:
        cores = {}
        total_pct = 0.0
        try:
            with open("/proc/stat", "r") as f:
                for line in f:
                    if line.startswith("cpu"):
                        parts = line.split()
                        name = parts[0]
                        user, nice, sys_t, idle, iowait, irq, softirq = [float(x) for x in parts[1:8]]
                        idle_t = idle + iowait
                        non_idle = user + nice + sys_t + irq + softirq
                        total = idle_t + non_idle

                        if name in self._last_cpu_times:
                            prev_total, prev_idle = self._last_cpu_times[name]
                            d_total = total - prev_total
                            d_idle = idle_t - prev_idle
                            if d_total > 0:
                                pct = max(0.0, min(100.0, ((d_total - d_idle) / d_total) * 100.0))
                            else:
                                pct = 0.0
                        else:
                            pct = 0.0

                        self._last_cpu_times[name] = (total, idle_t)

                        if name == "cpu":
                            total_pct = pct
                        else:
                            cores[name.upper()] = round(pct, 1)
        except Exception:
            pass

        return {
            "overall_percent": round(total_pct, 1),
            "cores": cores,
        }

    def _read_thermal_zones(self) -> Dict[str, float]:
        res = {"cpu_c": 0.0, "gpu_c": 0.0, "ao_c": 0.0}
        thermal_base = "/sys/devices/virtual/thermal"
        if not os.path.exists(thermal_base):
            return res

        try:
            for zone in os.listdir(thermal_base):
                if zone.startswith("thermal_zone"):
                    zpath = os.path.join(thermal_base, zone)
                    type_file = os.path.join(zpath, "type")
                    temp_file = os.path.join(zpath, "temp")
                    if os.path.exists(type_file) and os.path.exists(temp_file):
                        with open(type_file, "r") as f:
                            ztype = f.read().strip().lower()
                        with open(temp_file, "r") as f:
                            raw_temp = float(f.read().strip()) / 1000.0

                        if "cpu" in ztype:
                            res["cpu_c"] = round(raw_temp, 1)
                        elif "gpu" in ztype:
                            res["gpu_c"] = round(raw_temp, 1)
                        elif "ao" in ztype or "soc" in ztype:
                            res["ao_c"] = round(raw_temp, 1)
        except Exception:
            pass
        return res

    def _read_sysfs_gpu_load(self) -> float:
        paths = [
            "/sys/devices/platform/17000000.ga10b/load",
            "/sys/class/devfreq/17000000.ga10b/device/load",
            "/sys/devices/gpu.0/load",
            "/sys/devices/17000000.ga10b/devfreq/17000000.ga10b/load",
        ]
        for p in paths:
            if os.path.exists(p):
                try:
                    with open(p, "r") as f:
                        val = int(f.read().strip())
                        return float(val) / 10.0 if val > 100 else float(val)
                except Exception:
                    pass
        return 0.0

    def _read_iio_power_watts(self) -> float:
        """Reads power from sysfs hwmon / iio ina3221 or similar sensors."""
        hwmon_base = "/sys/class/hwmon"
        if os.path.exists(hwmon_base):
            try:
                for hw in os.listdir(hwmon_base):
                    hw_dir = os.path.join(hwmon_base, hw)
                    for fn in os.listdir(hw_dir):
                        if fn.startswith("power") and fn.endswith("_input"):
                            with open(os.path.join(hw_dir, fn), "r") as f:
                                uw = int(f.read().strip())
                                return round(uw / 1000000.0, 2)
            except Exception:
                pass
        return 0.0


if __name__ == "__main__":
    collector = TelemetryCollector()
    collector.start()
    try:
        for _ in range(3):
            time.sleep(1)
            import json
            print(json.dumps(collector.get_snapshot(), indent=2))
    finally:
        collector.stop()

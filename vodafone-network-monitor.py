#!/usr/bin/env python3
"""Live Vodafone hotspot monitor for Windows; Python standard library only."""

from __future__ import annotations

import csv
import ctypes
import http.client
import math
import os
import queue
import re
import shutil
import socket
import ssl
import subprocess
import threading
import time
import tkinter as tk
from collections import deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from ctypes import wintypes
from datetime import datetime, timedelta
from pathlib import Path
from tkinter import messagebox, ttk
from typing import Any


HERE = Path(__file__).resolve().parent
PING_HOSTS = ("1.1.1.1", "8.8.8.8")
DOWNLOAD_HOST = "speed.cloudflare.com"
DOWNLOAD_PATH = "/__down?bytes=65536"
UPLOAD_PATH = "/__up"
DOWNLOAD_BYTES = 64 * 1024
UPLOAD_BYTES = 32 * 1024
DEFAULT_INTERVAL = 5

CSV_FIELDS = [
    "timestamp_local", "sample_number", "status", "anomaly_details",
    "default_gateway", "computer_ip", "gateway_ping_ms",
    "ping_1_1_1_1_ms", "ping_8_8_8_8_ms", "dns_ms",
    "download_kib_s", "download_ms", "download_error",
    "upload_kib_s", "upload_ms", "upload_error",
    "android_adb", "operator", "data_registration", "data_network",
    "data_connection_state", "manual_network_selection", "rsrp_dbm",
    "rsrq_db", "rssnr_db", "lte_channel", "lte_bandwidth_khz",
    "physical_cell_id", "downlink_est_kbps", "uplink_est_kbps",
    "radio_reading_age_seconds",
]


def local_timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def text_from_process(result: subprocess.CompletedProcess[str]) -> str:
    return (result.stdout or "") + (result.stderr or "")


def run_text(command: list[str], timeout: float = 5.0) -> str:
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="mbcs" if os.name == "nt" else "utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        return text_from_process(completed)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"ERROR: {exc}"


def discover_adb() -> str | None:
    nearby = HERE / "platform-tools" / ("adb.exe" if os.name == "nt" else "adb")
    if nearby.is_file():
        return str(nearby)
    return shutil.which("adb.exe") or shutil.which("adb")


def default_route() -> dict[str, str]:
    if os.name != "nt":
        return {"gateway": "", "local_ip": "", "interface_alias": "", "route_note": "Windows route details unavailable"}
    output = run_text(["route.exe", "print", "-4"], timeout=4.0)
    matches = re.findall(
        r"(?m)^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d{1,3}(?:\.\d{1,3}){3})\s+"
        r"(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s*$",
        output,
    )
    if not matches:
        return {"gateway": "", "local_ip": "", "interface_alias": "", "route_note": "Маршрут по умолчанию не найден"}
    gateway, local_ip, _metric = min(matches, key=lambda item: int(item[2]))
    alias_cmd = (
        "$ip = Get-NetIPAddress -IPAddress '" + local_ip + "' -ErrorAction SilentlyContinue | "
        "Select-Object -First 1 -ExpandProperty InterfaceAlias; $ip"
    )
    alias = run_text(["powershell.exe", "-NoProfile", "-Command", alias_cmd], timeout=4.0).strip()
    if alias.startswith("ERROR:"):
        alias = ""
    return {"gateway": gateway, "local_ip": local_ip, "interface_alias": alias, "route_note": ""}


def ping_once(host: str, source_ip: str = "") -> dict[str, Any]:
    command = ["ping.exe" if os.name == "nt" else "ping", "-n" if os.name == "nt" else "-c", "1"]
    command += ["-w", "1200"] if os.name == "nt" else ["-W", "2"]
    if source_ip and os.name == "nt":
        command += ["-S", source_ip]
    command.append(host)
    started = time.perf_counter()
    output = run_text(command, timeout=3.0)
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    if output.startswith("ERROR:"):
        return {"ok": False, "ms": None, "error": output[7:].strip()[:160]}
    if re.search(r"(?im)(?:TTL|ttl)\s*[=<>]", output):
        match = re.search(
            r"(?i)(?:time|время|час)\s*[=<]\s*([\d]+(?:[.,][\d]+)?)\s*(?:ms|мс|msec|мсек)",
            output,
        )
        if match:
            value = float(match.group(1).replace(",", "."))
            if "<" in match.group(0):
                value = max(value, 1.0)
            return {"ok": True, "ms": round(value, 1), "error": ""}
        return {"ok": True, "ms": round(elapsed_ms, 1), "error": ""}
    return {"ok": False, "ms": None, "error": "нет ответа"}


def dns_probe() -> dict[str, Any]:
    started = time.perf_counter()
    try:
        socket.getaddrinfo(DOWNLOAD_HOST, 443, type=socket.SOCK_STREAM)
        return {"ok": True, "ms": round((time.perf_counter() - started) * 1000, 1), "error": ""}
    except OSError as exc:
        return {"ok": False, "ms": None, "error": str(exc)[:160]}


def https_transfer(method: str, path: str, source_ip: str, body: bytes = b"") -> dict[str, Any]:
    started = time.perf_counter()
    connection: http.client.HTTPSConnection | None = None
    try:
        source_address = (source_ip, 0) if source_ip else None
        connection = http.client.HTTPSConnection(
            DOWNLOAD_HOST,
            timeout=4.0,
            context=ssl.create_default_context(),
            source_address=source_address,
        )
        headers = {
            "User-Agent": "VodafoneConnectionMonitor/1.0",
            "Cache-Control": "no-cache",
            "Accept-Encoding": "identity",
        }
        if method == "POST":
            headers["Content-Type"] = "application/octet-stream"
        connection.request(method, path, body=body if method == "POST" else None, headers=headers)
        response = connection.getresponse()
        if not (200 <= response.status < 300):
            raise OSError(f"HTTP {response.status} {response.reason}")
        payload = response.read(DOWNLOAD_BYTES if method == "GET" else 2048)
        duration = max(time.perf_counter() - started, 0.001)
        transferred = DOWNLOAD_BYTES if method == "GET" else len(body)
        if method == "GET":
            transferred = min(len(payload), DOWNLOAD_BYTES)
        if transferred <= 0:
            raise OSError("Пустой ответ сервера")
        return {
            "ok": True,
            "ms": round(duration * 1000, 1),
            "kib_s": round(transferred / 1024 / duration, 2),
            "bytes": transferred,
            "error": "",
        }
    except (OSError, ssl.SSLError, http.client.HTTPException, TimeoutError) as exc:
        return {"ok": False, "ms": round((time.perf_counter() - started) * 1000, 1), "kib_s": None, "bytes": 0, "error": str(exc)[:200]}
    finally:
        if connection is not None:
            try:
                connection.close()
            except OSError:
                pass


def parse_android_dump(raw: str) -> dict[str, Any]:
    blocks = re.split(r"(?m)^\s*Phone Id=\d+\s*$", raw)
    candidates = [block for block in blocks[1:] if block.strip()]
    if not candidates:
        candidates = [raw]
    selected = next(
        (block for block in candidates if re.search(r"(?i)mOperatorAlpha(?:Long|Short)=\s*[^,\r\n]*vodafone", block)),
        next((block for block in candidates if re.search(r"mLte=CellSignalStrengthLte:", block)), candidates[-1]),
    )

    def group(pattern: str, default: str = "") -> str:
        match = re.search(pattern, selected)
        return match.group(1).strip() if match else default

    signal_line = group(r"(?m)^\s*mSignalStrength=(.*)$")
    lte = re.search(
        r"mLte=CellSignalStrengthLte:[^\r\n]*?rsrp=(-?\d+)[^\r\n]*?rsrq=(-?\d+)[^\r\n]*?rssnr=(-?\d+)",
        signal_line,
    )
    data_reg = re.search(r"mDataRegState=(\d+)\(([^)]+)\)", selected)
    rat = re.search(r"getRilDataRadioTechnology=\d+\(([^)]+)\)", selected)
    data_conn = re.search(r"(?m)^\s*mDataConnectionState=(\d+)", selected)
    down = re.search(r"mDownlinkCapacityKbps=(-?\d+)", selected)
    up = re.search(r"mUplinkCapacityKbps=(-?\d+)", selected)
    phys = re.search(r"mPhysicalCellId=(\d+)", selected)
    bandwidth = re.search(r"mCellBandwidthDownlinkKhz=(\d+)", selected)
    channel = re.search(r"mChannelNumber=(-?\d+)", selected)
    operator = group(r"mOperatorAlphaLong=([^,\r\n]*)", "неизвестен")
    manual = group(r"isManualNetworkSelection=(true|false)\(([^)]+)\)")
    if manual:
        manual = manual.split("(", 1)[0]
    return {
        "operator": operator,
        "data_registration": data_reg.group(2) if data_reg else "неизвестно",
        "data_reg_code": int(data_reg.group(1)) if data_reg else None,
        "data_network": rat.group(1) if rat else "неизвестно",
        "data_connection_state": int(data_conn.group(1)) if data_conn else None,
        "manual_network_selection": manual,
        "rsrp_dbm": int(lte.group(1)) if lte else None,
        "rsrq_db": int(lte.group(2)) if lte else None,
        "rssnr_db": int(lte.group(3)) if lte else None,
        "lte_channel": int(channel.group(1)) if channel else None,
        "lte_bandwidth_khz": int(bandwidth.group(1)) if bandwidth else None,
        "physical_cell_id": int(phys.group(1)) if phys else None,
        "downlink_est_kbps": int(down.group(1)) if down else None,
        "uplink_est_kbps": int(up.group(1)) if up else None,
        "radio_error": "",
    }


def capture_android(adb_path: str | None) -> dict[str, Any]:
    empty = {
        "adb_status": "нет ADB",
        "operator": "",
        "data_registration": "",
        "data_reg_code": None,
        "data_network": "",
        "data_connection_state": None,
        "manual_network_selection": "",
        "rsrp_dbm": None,
        "rsrq_db": None,
        "rssnr_db": None,
        "lte_channel": None,
        "lte_bandwidth_khz": None,
        "physical_cell_id": None,
        "downlink_est_kbps": None,
        "uplink_est_kbps": None,
        "radio_error": "",
    }
    if not adb_path:
        empty["adb_status"] = "adb.exe не найден"
        return empty
    devices_text = run_text([adb_path, "devices"], timeout=4.0)
    online = re.findall(r"(?m)^\s*(\S+)\s+device\s*$", devices_text)
    if not online:
        if re.search(r"(?m)^\s*\S+\s+unauthorized\s*$", devices_text):
            empty["adb_status"] = "разблокируйте Android и разрешите USB debugging"
        elif re.search(r"(?m)^\s*\S+\s+offline\s*$", devices_text):
            empty["adb_status"] = "Android по USB сейчас offline"
        else:
            empty["adb_status"] = "Android не подключён по ADB"
        return empty
    serial = online[0]
    raw = run_text([adb_path, "-s", serial, "shell", "dumpsys", "telephony.registry"], timeout=5.0)
    if raw.startswith("ERROR:") or "mServiceState" not in raw:
        empty["adb_status"] = "не удалось прочитать радиосостояние"
        empty["radio_error"] = raw[:180]
        return empty
    try:
        parsed = parse_android_dump(raw)
    except (ValueError, IndexError, AttributeError) as exc:
        empty["adb_status"] = "не удалось разобрать радиосостояние"
        empty["radio_error"] = str(exc)[:180]
        return empty
    parsed["adb_status"] = "Android подключён" if len(online) == 1 else f"Android подключён; устройств: {len(online)}"
    return parsed


def analyze(sample: dict[str, Any]) -> tuple[str, list[str]]:
    critical: list[str] = []
    warnings: list[str] = []
    gateway_ping = sample.get("gateway_ping")
    pings = [sample.get("ping_results", {}).get(host, {}).get("ms") for host in PING_HOSTS]
    answered = sum(value is not None for value in pings)

    if sample.get("gateway") and gateway_ping is None and answered == 0:
        critical.append("нет ответа от шлюза точки доступа и внешних узлов")
    elif answered == 0:
        critical.append("оба внешних узла не отвечают на ping")
    elif sample.get("gateway") and gateway_ping is None:
        warnings.append("шлюз не ответил на ping, но внешние узлы доступны")
    if gateway_ping is not None and gateway_ping >= 250:
        critical.append(f"очень высокая задержка до телефона/шлюза {gateway_ping:.0f} ms")
    elif gateway_ping is not None and gateway_ping >= 80:
        warnings.append(f"высокая задержка до телефона/шлюза {gateway_ping:.0f} ms")
    elif answered == 1:
        warnings.append("один из двух узлов не ответил на ping")
    if answered and max(value for value in pings if value is not None) >= 500:
        warnings.append("очень высокая задержка до интернета")

    download = sample.get("download")
    if download and download.get("ok") and download.get("kib_s") is not None:
        if download["kib_s"] < 10:
            critical.append(f"загрузка {download['kib_s']:.1f} KiB/s")
        elif download["kib_s"] < 30:
            warnings.append(f"низкая загрузка {download['kib_s']:.1f} KiB/s")
    elif download and not download.get("ok"):
        warnings.append("HTTPS-загрузка с контрольного сервера не прошла")

    upload = sample.get("upload")
    if upload and upload.get("ok") and upload.get("kib_s") is not None:
        if upload["kib_s"] < 2:
            critical.append(f"отдача {upload['kib_s']:.1f} KiB/s")
        elif upload["kib_s"] < 8:
            warnings.append(f"низкая отдача {upload['kib_s']:.1f} KiB/s")
    elif upload and not upload.get("ok"):
        warnings.append("HTTPS-отправка на контрольный сервер не прошла")

    radio = sample.get("radio") or {}
    if radio.get("data_reg_code") is not None and radio["data_reg_code"] != 0:
        critical.append(f"мобильная регистрация: {radio.get('data_registration', 'нет сети')}")
    if radio.get("data_connection_state") == 0 and radio.get("data_reg_code") == 0:
        warnings.append("LTE зарегистрирован, но соединение передачи данных не активно")
    rsrp = radio.get("rsrp_dbm")
    rsrq = radio.get("rsrq_db")
    sinr = radio.get("rssnr_db")
    if rsrp is not None and rsrp <= -120:
        critical.append(f"очень слабый LTE-сигнал RSRP {rsrp} dBm")
    elif rsrp is not None and rsrp <= -115:
        warnings.append(f"слабый LTE-сигнал RSRP {rsrp} dBm")
    if rsrq is not None and rsrq <= -20:
        critical.append(f"очень плохое качество LTE RSRQ {rsrq} dB")
    elif rsrq is not None and rsrq <= -17:
        warnings.append(f"плохое качество LTE RSRQ {rsrq} dB")
    if sinr is not None and sinr < -3:
        critical.append(f"низкое отношение сигнал/шум LTE RSSNR {sinr} dB")
    elif sinr is not None and sinr < 0:
        warnings.append(f"низкое отношение сигнал/шум LTE RSSNR {sinr} dB")

    if critical:
        return "СБОЙ", critical + warnings
    if warnings:
        return "НЕСТАБИЛЬНО", warnings
    return "НОРМА", []


class VodafoneMonitor:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.base_window_title = "Монитор Vodafone — мобильная точка доступа"
        self.alert_window_title = "⚠ Нестабильное подключение — монитор Vodafone"
        self.root.title(self.base_window_title)
        self.root.geometry("980x700")
        self.root.minsize(760, 580)
        self.root.configure(bg="#f3f5f8")
        self.root.protocol("WM_DELETE_WINDOW", self.close)

        self.messages: queue.Queue[tuple[str, Any]] = queue.Queue()
        self.stop_event = threading.Event()
        self.worker: threading.Thread | None = None
        self.running = False
        self.attention_active = False
        self.interval_var = tk.StringVar(value=str(DEFAULT_INTERVAL))
        self.run_dir: Path | None = None
        self.last_status = "НОРМА"
        self.sample_count = 0
        self.latest_values: dict[str, Any] = {}
        self.history: deque[dict[str, Any]] = deque(maxlen=20000)
        self.chart_window: tk.Toplevel | None = None
        self.chart_canvases: dict[str, tk.Canvas] = {}
        self.chart_period_var = tk.StringVar(value="15 минут")
        self.chart_info_var = tk.StringVar(value="График показывает последние 15 минут; полный журнал остаётся в CSV.")
        self.chart_redraw_after: str | None = None
        self.adb_path = discover_adb()
        self._build_ui()
        self.root.after(200, self._drain_messages)
        self.start_monitoring()

    def _build_ui(self) -> None:
        header = tk.Frame(self.root, bg="#f3f5f8", padx=18, pady=14)
        header.pack(fill="x")
        tk.Label(header, text="Vodafone • живая диагностика", font=("Segoe UI", 18, "bold"), bg="#f3f5f8", fg="#182230").pack(anchor="w")
        tk.Label(
            header,
            text="Компьютер должен быть подключён именно к точке доступа телефона. Android по USB добавит параметры LTE.",
            font=("Segoe UI", 10), bg="#f3f5f8", fg="#475467",
        ).pack(anchor="w", pady=(4, 0))

        controls = tk.Frame(self.root, bg="#ffffff", padx=14, pady=10, highlightbackground="#d0d5dd", highlightthickness=1)
        controls.pack(fill="x", padx=18, pady=(0, 12))
        tk.Label(controls, text="Интервал:", font=("Segoe UI", 10), bg="white", fg="#344054").pack(side="left")
        interval = ttk.Combobox(controls, textvariable=self.interval_var, values=("5", "10", "15"), width=4, state="readonly")
        interval.pack(side="left", padx=(6, 14))
        tk.Label(controls, text="сек", font=("Segoe UI", 10), bg="white", fg="#344054").pack(side="left")
        self.start_button = ttk.Button(controls, text="Начать", command=self.start_monitoring)
        self.start_button.pack(side="left", padx=(18, 5))
        self.stop_button = ttk.Button(controls, text="Остановить", command=self.stop_monitoring, state="disabled")
        self.stop_button.pack(side="left", padx=5)
        ttk.Button(controls, text="Открыть папку журнала", command=self.open_log_folder).pack(side="right")
        ttk.Button(controls, text="Графики", command=self.open_charts).pack(side="right", padx=(0, 8))

        self.status_banner = tk.Label(
            self.root, text="Запускаю проверки…", font=("Segoe UI", 13, "bold"),
            bg="#eaf2ff", fg="#1849a9", padx=16, pady=10, anchor="w",
        )
        self.status_banner.pack(fill="x", padx=18, pady=(0, 10))

        self.route_label = tk.Label(self.root, text="Маршрут: определяю…", font=("Segoe UI", 9), bg="#f3f5f8", fg="#475467", anchor="w")
        self.route_label.pack(fill="x", padx=20, pady=(0, 8))

        cards = tk.Frame(self.root, bg="#f3f5f8")
        cards.pack(fill="both", expand=True, padx=18)
        for col in range(3):
            cards.grid_columnconfigure(col, weight=1, uniform="cards")
        for row in range(2):
            cards.grid_rowconfigure(row, weight=1, uniform="cards")

        self.metric_vars: dict[str, tk.StringVar] = {}
        cards_data = [
            ("local", "Точка доступа → компьютер"),
            ("internet", "Интернет: ping и DNS"),
            ("speed", "Скорость контрольной передачи"),
            ("radio", "Регистрация мобильной сети"),
            ("signal", "LTE: уровень и качество"),
            ("capacity", "Оценка модема и ADB"),
        ]
        for index, (key, title) in enumerate(cards_data):
            frame = tk.Frame(cards, bg="white", padx=14, pady=12, highlightbackground="#d0d5dd", highlightthickness=1)
            frame.grid(row=index // 3, column=index % 3, sticky="nsew", padx=5, pady=5)
            tk.Label(frame, text=title, font=("Segoe UI", 10, "bold"), bg="white", fg="#344054", anchor="w").pack(fill="x")
            value = tk.StringVar(value="Ожидание первого замера")
            self.metric_vars[key] = value
            value_label = tk.Label(frame, textvariable=value, font=("Segoe UI", 12), bg="white", fg="#182230", anchor="nw", justify="left", wraplength=275)
            value_label.pack(fill="both", expand=True, pady=(9, 0))
            setattr(self, f"{key}_label", value_label)

        events_frame = tk.Frame(self.root, bg="white", padx=12, pady=10, highlightbackground="#d0d5dd", highlightthickness=1)
        events_frame.pack(fill="both", expand=True, padx=18, pady=(10, 16))
        tk.Label(events_frame, text="Последние события", font=("Segoe UI", 10, "bold"), bg="white", fg="#344054").pack(anchor="w")
        self.events_text = tk.Text(events_frame, height=7, wrap="word", state="disabled", font=("Consolas", 9), bg="#fbfcfe", fg="#344054", relief="flat")
        self.events_text.pack(fill="both", expand=True, pady=(6, 0))
        self.events_text.tag_configure("bad", foreground="#b42318")
        self.events_text.tag_configure("warn", foreground="#b54708")
        self.events_text.tag_configure("good", foreground="#027a48")

    def open_charts(self) -> None:
        if self.chart_window is not None and self.chart_window.winfo_exists():
            if self.chart_window.state() == "iconic":
                self.chart_window.deiconify()
            self.chart_window.lift()
            self.render_charts()
            return

        window = tk.Toplevel(self.root)
        self.chart_window = window
        window.title("Графики мобильного интернета")
        window.geometry("1180x820")
        window.minsize(900, 620)
        window.configure(bg="#f3f5f8")
        window.protocol("WM_DELETE_WINDOW", self.close_charts)

        toolbar = tk.Frame(window, bg="#f3f5f8", padx=14, pady=12)
        toolbar.pack(fill="x")
        tk.Label(toolbar, text="Период на графике:", font=("Segoe UI", 10), bg="#f3f5f8", fg="#344054").pack(side="left")
        period = ttk.Combobox(
            toolbar,
            textvariable=self.chart_period_var,
            values=("5 минут", "15 минут", "30 минут", "60 минут", "Весь сеанс"),
            state="readonly",
            width=13,
        )
        period.pack(side="left", padx=(8, 14))
        period.bind("<<ComboboxSelected>>", lambda _event: self.render_charts())
        tk.Label(toolbar, textvariable=self.chart_info_var, font=("Segoe UI", 9), bg="#f3f5f8", fg="#475467").pack(side="left", fill="x", expand=True)

        plots = tk.Frame(window, bg="#f3f5f8")
        plots.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        for column in range(2):
            plots.grid_columnconfigure(column, weight=1, uniform="plot-columns")
        for row in range(2):
            plots.grid_rowconfigure(row, weight=1, uniform="plot-rows")

        plot_specs = (
            ("latency", "Задержка до точки доступа и интернета"),
            ("speed", "Контрольная скорость загрузки и отдачи"),
            ("rsrp", "Уровень сигнала LTE (RSRP)"),
            ("quality", "Качество LTE (RSRQ и RSSNR)"),
        )
        self.chart_canvases = {}
        for index, (key, title) in enumerate(plot_specs):
            card = tk.Frame(plots, bg="white", highlightbackground="#d0d5dd", highlightthickness=1)
            card.grid(row=index // 2, column=index % 2, sticky="nsew", padx=5, pady=5)
            canvas = tk.Canvas(card, bg="white", highlightthickness=0, height=300)
            canvas.pack(fill="both", expand=True, padx=6, pady=6)
            canvas.bind("<Configure>", self._schedule_chart_redraw)
            self.chart_canvases[key] = canvas

        tk.Label(
            window,
            text="Серые промежутки означают, что замер не выполнялся; красная пунктирная отметка — обнаруженное отклонение. Полная история продолжает сохраняться в CSV.",
            font=("Segoe UI", 9), bg="#f3f5f8", fg="#475467", anchor="w", padx=16, pady=8,
        ).pack(fill="x")
        self.render_charts()

    def close_charts(self) -> None:
        if self.chart_redraw_after is not None:
            try:
                self.root.after_cancel(self.chart_redraw_after)
            except tk.TclError:
                pass
            self.chart_redraw_after = None
        if self.chart_window is not None:
            try:
                self.chart_window.destroy()
            except tk.TclError:
                pass
        self.chart_window = None
        self.chart_canvases = {}

    def _schedule_chart_redraw(self, _event: Any = None) -> None:
        if self.chart_redraw_after is not None:
            try:
                self.root.after_cancel(self.chart_redraw_after)
            except tk.TclError:
                pass
        self.chart_redraw_after = self.root.after(180, self.render_charts)

    def render_charts(self) -> None:
        if self.chart_window is None or not self.chart_window.winfo_exists():
            return
        records = list(self.history)
        period = self.chart_period_var.get()
        minutes = {"5 минут": 5, "15 минут": 15, "30 минут": 30, "60 минут": 60}.get(period)
        if records:
            end = records[-1]["when"]
            if minutes is not None:
                start = max(records[0]["when"], end - timedelta(minutes=minutes))
                records = [record for record in records if record["when"] >= start]
            else:
                start = records[0]["when"]
            if records:
                self.chart_info_var.set(
                    f"Точек: {len(records)} • {records[0]['when'].strftime('%H:%M:%S')} — {records[-1]['when'].strftime('%H:%M:%S')}"
                )
            else:
                self.chart_info_var.set("Ждём первые замеры для выбранного периода.")
        else:
            end = datetime.now().astimezone()
            start = end - timedelta(minutes=minutes or 15)
            self.chart_info_var.set("Ждём первые замеры.")

        definitions = {
            "latency": (
                "Задержка, мс",
                [
                    ("Шлюз телефона", "gateway_ms", "#667085", 15, ""),
                    ("1.1.1.1", "ping_1", "#1570ef", 15, ""),
                    ("8.8.8.8", "ping_2", "#12b76a", 15, ""),
                ],
                "latency",
            ),
            "speed": (
                "Скорость, KiB/s",
                [
                    ("Загрузка", "download_kib_s", "#1570ef", 60, "download_failed"),
                    ("Отдача", "upload_kib_s", "#f79009", 90, "upload_failed"),
                ],
                "zero",
            ),
            "rsrp": (
                "RSRP, dBm",
                [("Уровень сигнала", "rsrp", "#d92d20", 30, "")],
                "rsrp",
            ),
            "quality": (
                "Качество, dB",
                [
                    ("RSRQ", "rsrq", "#7a5af8", 30, ""),
                    ("RSSNR", "rssnr", "#1570ef", 30, ""),
                ],
                "quality",
            ),
        }
        for key, canvas in self.chart_canvases.items():
            title, series, scale = definitions[key]
            self._draw_chart(canvas, title, series, scale, records, start, end)
        self.chart_redraw_after = None

    def _draw_chart(
        self,
        canvas: tk.Canvas,
        y_title: str,
        series: list[tuple[str, str, str, int, str]],
        scale: str,
        records: list[dict[str, Any]],
        start: datetime,
        end: datetime,
    ) -> None:
        canvas.delete("all")
        width = max(canvas.winfo_width(), 360)
        height = max(canvas.winfo_height(), 220)
        left, right, top, bottom = 62, width - 18, 58, height - 42
        plot_width = max(right - left, 1)
        plot_height = max(bottom - top, 1)
        canvas.create_text(left, 17, text=y_title, anchor="w", font=("Segoe UI", 10, "bold"), fill="#344054")

        all_values = [
            float(record[key])
            for record in records
            for _label, key, _color, _gap, _failed in series
            if isinstance(record.get(key), (int, float)) and math.isfinite(float(record[key]))
        ]
        if not all_values:
            canvas.create_text(width / 2, height / 2, text="Нет замеров за выбранный период", font=("Segoe UI", 11), fill="#667085")
            return

        if scale == "zero":
            y_min = 0.0
            maximum = max(all_values)
            step = 10 if maximum <= 50 else 25 if maximum <= 200 else 100
            y_max = max(step * 4, math.ceil(maximum / step) * step)
        elif scale == "latency":
            y_min = 0.0
            y_max = max(100.0, math.ceil(max(all_values) / 100) * 100)
        elif scale == "rsrp":
            y_min = min(-125.0, math.floor((min(all_values) - 5) / 5) * 5)
            y_max = max(-70.0, math.ceil((max(all_values) + 5) / 5) * 5)
        else:
            y_min = math.floor((min(all_values) - 5) / 5) * 5
            y_max = math.ceil((max(all_values) + 5) / 5) * 5
            if y_max - y_min < 20:
                y_min -= 5
                y_max += 5

        def x_for(moment: datetime) -> float:
            duration = max((end - start).total_seconds(), 1.0)
            ratio = (moment - start).total_seconds() / duration
            return left + min(max(ratio, 0.0), 1.0) * plot_width

        def y_for(value: float) -> float:
            ratio = (value - y_min) / max(y_max - y_min, 1.0)
            return bottom - min(max(ratio, 0.0), 1.0) * plot_height

        for index in range(5):
            fraction = index / 4
            y = bottom - fraction * plot_height
            value = y_min + fraction * (y_max - y_min)
            label = f"{value:.0f}" if abs(value) >= 10 or float(value).is_integer() else f"{value:.1f}"
            canvas.create_line(left, y, right, y, fill="#eaecf0", width=1)
            canvas.create_text(left - 8, y, text=label, anchor="e", font=("Segoe UI", 8), fill="#667085")

        duration_minutes = max((end - start).total_seconds() / 60, 1)
        time_format = "%H:%M:%S" if duration_minutes <= 5 else "%H:%M"
        for index in range(5):
            fraction = index / 4
            x = left + fraction * plot_width
            moment = start + (end - start) * fraction
            canvas.create_line(x, top, x, bottom, fill="#f2f4f7", width=1)
            canvas.create_text(x, bottom + 16, text=moment.strftime(time_format), anchor="n", font=("Segoe UI", 8), fill="#667085")

        display_records = records
        if len(display_records) > 600:
            stride = math.ceil(len(display_records) / 600)
            display_records = display_records[::stride]
            if display_records[-1] is not records[-1]:
                display_records.append(records[-1])

        previous_status = "НОРМА"
        for record in display_records:
            status = record.get("status", "НОРМА")
            if status != "НОРМА" and previous_status == "НОРМА":
                x = x_for(record["when"])
                canvas.create_line(x, top, x, bottom, fill="#fda29b", dash=(3, 4), width=1)
            previous_status = status

        for label, key, color, max_gap, failed_key in series:
            previous: tuple[float, float, datetime] | None = None
            for record in display_records:
                value = record.get(key)
                if not isinstance(value, (int, float)) or not math.isfinite(float(value)):
                    previous = None if previous and (record["when"] - previous[2]).total_seconds() > max_gap else previous
                    continue
                moment = record["when"]
                point = (x_for(moment), y_for(float(value)), moment)
                if previous and (moment - previous[2]).total_seconds() <= max_gap:
                    canvas.create_line(previous[0], previous[1], point[0], point[1], fill=color, width=2)
                if failed_key and record.get(failed_key):
                    size = 4
                    canvas.create_line(point[0] - size, point[1] - size, point[0] + size, point[1] + size, fill="#d92d20", width=2)
                    canvas.create_line(point[0] - size, point[1] + size, point[0] + size, point[1] - size, fill="#d92d20", width=2)
                else:
                    canvas.create_oval(point[0] - 2.5, point[1] - 2.5, point[0] + 2.5, point[1] + 2.5, fill=color, outline=color)
                previous = point

        legend_x = left
        legend_y = 39
        for label, _key, color, _gap, _failed in series:
            canvas.create_line(legend_x, legend_y, legend_x + 18, legend_y, fill=color, width=3)
            canvas.create_text(legend_x + 23, legend_y, text=label, anchor="w", font=("Segoe UI", 8), fill="#475467")
            legend_x += 35 + len(label) * 6

    def _remember_sample(self, sample: dict[str, Any]) -> None:
        try:
            moment = datetime.fromisoformat(sample["timestamp_local"])
        except (KeyError, TypeError, ValueError):
            moment = datetime.now().astimezone()
        radio = sample.get("radio") or {}
        download = sample.get("download") or {}
        upload = sample.get("upload") or {}
        gateway_result = sample.get("gateway_result") or {}
        ping_results = sample.get("ping_results") or {}
        self.history.append({
            "when": moment,
            "status": sample.get("status", "НОРМА"),
            "gateway_ms": gateway_result.get("ms"),
            "ping_1": ping_results.get("1.1.1.1", {}).get("ms"),
            "ping_2": ping_results.get("8.8.8.8", {}).get("ms"),
            "download_kib_s": download.get("kib_s") if download.get("ok") else (0.0 if download else None),
            "download_failed": bool(download and not download.get("ok")),
            "upload_kib_s": upload.get("kib_s") if upload.get("ok") else (0.0 if upload else None),
            "upload_failed": bool(upload and not upload.get("ok")),
            "rsrp": radio.get("rsrp_dbm"),
            "rsrq": radio.get("rsrq_db"),
            "rssnr": radio.get("rssnr_db"),
        })
        if self.chart_window is not None and self.chart_window.winfo_exists():
            self._schedule_chart_redraw()

    def _make_run_directory(self) -> Path:
        directory = HERE / ("vodafone-monitor-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
        directory.mkdir(parents=True, exist_ok=False)
        readme = directory / "README.txt"
        readme.write_text(
            "Журнал диагностики мобильного интернета через точку доступа Vodafone.\n"
            f"Начало: {local_timestamp()}\n"
            f"Интервал проверок: {self.interval_var.get()} секунд.\n\n"
            "metrics.csv — замеры ping до телефона/шлюза и двух внешних IP, DNS, небольшие HTTPS-передачи,\n"
            "а также доступные через Android ADB сведения о регистрации, LTE-сигнале и оценке модема.\n"
            "Контрольная загрузка 64 KiB выполняется примерно каждые 15 секунд; отправка 32 KiB — каждые 30 секунд.\n"
            "events.csv — моменты начала и окончания отклонений. Окно графиков показывает последние 15 минут по умолчанию;\n"
            "период просмотра можно менять, а полная запись не обрезается и остаётся в CSV.\n"
            "При отклонении приложение подсвечивается на панели задач и перестаёт мигать после восстановления сети.\n\n"
            "Для корректной проверки компьютер должен быть подключён к точке доступа телефона.\n"
            "При наличии Android подключите его USB-кабелем с передачей данных и разрешите USB debugging.\n"
            "Если USB/ADB отвалится, сетевые проверки компьютера продолжатся.\n\n"
            "Логи содержат точное время, параметры радиосети и идентификатор обслуживающей соты, если Android его выдаёт.\n"
            "Не выкладывайте их публично; передавайте только для разбора проблемы.\n",
            encoding="utf-8",
        )
        return directory

    def start_monitoring(self) -> None:
        if self.running:
            return
        try:
            interval = int(self.interval_var.get())
            if interval not in (5, 10, 15):
                interval = DEFAULT_INTERVAL
                self.interval_var.set(str(interval))
            self.run_dir = self._make_run_directory()
        except Exception as exc:
            messagebox.showerror("Не удалось начать журнал", str(exc))
            return
        self.stop_event.clear()
        self.running = True
        self.sample_count = 0
        self.history.clear()
        self.last_status = "НОРМА"
        self.start_button.configure(state="disabled")
        self.stop_button.configure(state="normal")
        self._event(f"Журнал начат: {self.run_dir}", "good")
        self.worker = threading.Thread(target=self._monitor_loop, args=(interval,), daemon=True)
        self.worker.start()

    def stop_monitoring(self) -> None:
        if not self.running:
            return
        self.stop_event.set()
        self.running = False
        self._set_attention(False)
        self.start_button.configure(state="normal")
        self.stop_button.configure(state="disabled")
        self.status_banner.configure(text="Сбор остановлен. CSV сохранён в папке журнала.", bg="#eef2f6", fg="#344054")
        self._event("Сбор остановлен пользователем", "good")

    def _monitor_loop(self, interval: int) -> None:
        csv_path = self.run_dir / "metrics.csv" if self.run_dir else None
        event_path = self.run_dir / "events.csv" if self.run_dir else None
        route = default_route()
        last_route_update = time.monotonic()
        radio_cache: dict[str, Any] = capture_android(self.adb_path)
        last_radio_update = 0.0
        last_status = "НОРМА"
        previous_transfer_error: dict[str, bool] = {"download": False, "upload": False}
        with csv_path.open("w", newline="", encoding="utf-8-sig") as metrics_file, event_path.open("w", newline="", encoding="utf-8-sig") as events_file:
            writer = csv.DictWriter(metrics_file, fieldnames=CSV_FIELDS, extrasaction="ignore")
            writer.writeheader()
            event_writer = csv.writer(events_file)
            event_writer.writerow(("timestamp_local", "status", "details"))
            metrics_file.flush()
            events_file.flush()

            while not self.stop_event.is_set():
                started = time.monotonic()
                self.sample_count += 1
                count = self.sample_count
                if started - last_route_update >= 60:
                    route = default_route()
                    last_route_update = started
                if count == 1 or count % 2 == 1 or started - last_radio_update >= 30:
                    radio_cache = capture_android(self.adb_path)
                    last_radio_update = time.monotonic()

                sample: dict[str, Any] = {
                    "timestamp_local": local_timestamp(),
                    "sample_number": count,
                    "gateway": route.get("gateway", ""),
                    "computer_ip": route.get("local_ip", ""),
                    "route_note": route.get("route_note", ""),
                    "radio": dict(radio_cache),
                    "radio_age": max(0, int(time.monotonic() - last_radio_update)),
                    "ping_results": {},
                    "gateway_ping": None,
                    "dns": None,
                    "download": None,
                    "upload": None,
                }

                tasks: dict[Any, tuple[str, str]] = {}
                with ThreadPoolExecutor(max_workers=6) as pool:
                    if route.get("gateway"):
                        tasks[pool.submit(ping_once, route["gateway"], route.get("local_ip", ""))] = ("gateway", route["gateway"])
                    for host in PING_HOSTS:
                        tasks[pool.submit(ping_once, host, route.get("local_ip", ""))] = ("ping", host)
                    if count % 3 == 1:
                        tasks[pool.submit(dns_probe)] = ("dns", "")
                        tasks[pool.submit(https_transfer, "GET", DOWNLOAD_PATH, route.get("local_ip", ""))] = ("download", "")
                    if count % 6 == 1:
                        tasks[pool.submit(https_transfer, "POST", UPLOAD_PATH, route.get("local_ip", ""), b"V" * UPLOAD_BYTES)] = ("upload", "")
                    for future in as_completed(tasks):
                        kind, key = tasks[future]
                        try:
                            result = future.result()
                        except Exception as exc:
                            result = {"ok": False, "ms": None, "kib_s": None, "error": str(exc)[:160]}
                        if kind == "gateway":
                            sample["gateway_ping"] = result.get("ms")
                            sample["gateway_result"] = result
                        elif kind == "ping":
                            sample["ping_results"][key] = result
                        else:
                            sample[kind] = result

                status, details = analyze(sample)
                sample["status"] = status
                sample["details"] = details
                sample["radio"]["adb_status"] = sample["radio"].get("adb_status", "")
                row = self._csv_row(sample)
                writer.writerow(row)
                metrics_file.flush()

                if status != last_status:
                    event_writer.writerow((sample["timestamp_local"], status, "; ".join(details) if details else "Отклонение закончилось"))
                    events_file.flush()
                    self.messages.put(("status_transition", {"status": status, "details": details, "time": sample["timestamp_local"], "run_dir": str(self.run_dir)}))
                    if last_status == "НОРМА" and status != "НОРМА":
                        self.messages.put(("attention", True))
                    elif status == "НОРМА" and last_status != "НОРМА":
                        self.messages.put(("attention", False))
                    last_status = status
                elif details and status != "НОРМА" and count % 12 == 0:
                    event_writer.writerow((sample["timestamp_local"], status, "; ".join(details)))
                    events_file.flush()

                self.messages.put(("sample", sample))
                self.messages.put(("route", route))
                elapsed = time.monotonic() - started
                self.stop_event.wait(max(0.2, interval - elapsed))

    @staticmethod
    def _csv_row(sample: dict[str, Any]) -> dict[str, Any]:
        radio = sample.get("radio") or {}
        ping_results = sample.get("ping_results", {})
        gateway_result = sample.get("gateway_result", {})
        dns = sample.get("dns") or {}
        download = sample.get("download") or {}
        upload = sample.get("upload") or {}
        return {
            "timestamp_local": sample.get("timestamp_local"),
            "sample_number": sample.get("sample_number"),
            "status": sample.get("status"),
            "anomaly_details": "; ".join(sample.get("details", [])),
            "default_gateway": sample.get("gateway"),
            "computer_ip": sample.get("computer_ip"),
            "gateway_ping_ms": gateway_result.get("ms"),
            "ping_1_1_1_1_ms": ping_results.get("1.1.1.1", {}).get("ms"),
            "ping_8_8_8_8_ms": ping_results.get("8.8.8.8", {}).get("ms"),
            "dns_ms": dns.get("ms"),
            "download_kib_s": download.get("kib_s"),
            "download_ms": download.get("ms"),
            "download_error": download.get("error", ""),
            "upload_kib_s": upload.get("kib_s"),
            "upload_ms": upload.get("ms"),
            "upload_error": upload.get("error", ""),
            "android_adb": radio.get("adb_status"),
            "operator": radio.get("operator"),
            "data_registration": radio.get("data_registration"),
            "data_network": radio.get("data_network"),
            "data_connection_state": radio.get("data_connection_state"),
            "manual_network_selection": radio.get("manual_network_selection"),
            "rsrp_dbm": radio.get("rsrp_dbm"),
            "rsrq_db": radio.get("rsrq_db"),
            "rssnr_db": radio.get("rssnr_db"),
            "lte_channel": radio.get("lte_channel"),
            "lte_bandwidth_khz": radio.get("lte_bandwidth_khz"),
            "physical_cell_id": radio.get("physical_cell_id"),
            "downlink_est_kbps": radio.get("downlink_est_kbps"),
            "uplink_est_kbps": radio.get("uplink_est_kbps"),
            "radio_reading_age_seconds": sample.get("radio_age"),
        }

    def _drain_messages(self) -> None:
        try:
            while True:
                kind, payload = self.messages.get_nowait()
                if kind == "sample":
                    self._update_sample(payload)
                elif kind == "route":
                    gateway = payload.get("gateway") or "не найден"
                    local_ip = payload.get("local_ip") or "не найден"
                    alias = payload.get("interface_alias") or "интерфейс не определён"
                    suffix = f" • {payload['route_note']}" if payload.get("route_note") else ""
                    self.route_label.configure(text=f"Активный маршрут Windows: {alias} • шлюз {gateway} • IP компьютера {local_ip}{suffix}")
                elif kind == "status_transition":
                    self._status_event(payload)
                elif kind == "attention":
                    self._set_attention(bool(payload) and self.running)
        except queue.Empty:
            pass
        if self.root.winfo_exists():
            self.root.after(200, self._drain_messages)

    def _update_sample(self, sample: dict[str, Any]) -> None:
        self.latest_values = sample
        self._remember_sample(sample)
        status = sample.get("status", "НОРМА")
        details = sample.get("details", [])
        colors = {
            "НОРМА": ("#ecfdf3", "#027a48"),
            "НЕСТАБИЛЬНО": ("#fffaeb", "#b54708"),
            "СБОЙ": ("#fef3f2", "#b42318"),
        }
        bg, fg = colors.get(status, ("#eaf2ff", "#1849a9"))
        detail_text = "; ".join(details) if details else "существенных отклонений не обнаружено"
        self.status_banner.configure(text=f"{status} • {sample['timestamp_local']} • {detail_text}", bg=bg, fg=fg)

        gateway_result = sample.get("gateway_result", {})
        gateway_ms = gateway_result.get("ms")
        self.metric_vars["local"].set(
            f"Шлюз телефона: {sample.get('gateway') or 'не найден'}\n"
            f"Ответ: {gateway_ms:.1f} ms" if gateway_ms is not None else
            f"Шлюз телефона: {sample.get('gateway') or 'не найден'}\nОтвета нет"
        )
        self._color_metric("local", "bad" if sample.get("gateway") and gateway_ms is None else "normal")

        ping_results = sample.get("ping_results", {})
        def ping_line(host: str) -> str:
            result = ping_results.get(host, {})
            value = result.get("ms")
            return f"{host}: {value:.1f} ms" if value is not None else f"{host}: нет ответа"
        dns = sample.get("dns") or {}
        dns_line = f"DNS: {dns['ms']:.0f} ms" if dns.get("ok") else ("DNS: проверка через 15 сек" if not dns else "DNS: ошибка")
        self.metric_vars["internet"].set(f"{ping_line('1.1.1.1')}\n{ping_line('8.8.8.8')}\n{dns_line}")
        external_ok = sum(ping_results.get(host, {}).get("ms") is not None for host in PING_HOSTS)
        self._color_metric("internet", "bad" if external_ok == 0 else "warn" if external_ok == 1 or any((ping_results.get(h, {}).get("ms") or 0) >= 500 for h in PING_HOSTS) else "normal")

        download = sample.get("download") or {}
        upload = sample.get("upload") or {}
        dl = f"↓ {download['kib_s']:.1f} KiB/s" if download.get("kib_s") is not None else ("↓ ошибка HTTPS" if download and not download.get("ok") else "↓ замер каждые 15 сек")
        ul = f"↑ {upload['kib_s']:.1f} KiB/s" if upload.get("kib_s") is not None else ("↑ ошибка HTTPS" if upload and not upload.get("ok") else "↑ замер каждые 30 сек")
        self.metric_vars["speed"].set(f"{dl}\n{ul}\nСервер: Cloudflare • небольшие контрольные передачи")
        self._color_metric("speed", "bad" if (download.get("kib_s") is not None and download["kib_s"] < 10) or (upload.get("kib_s") is not None and upload["kib_s"] < 2) or (download and not download.get("ok")) else "warn" if download.get("kib_s") is not None and download["kib_s"] < 30 else "normal")

        radio = sample.get("radio") or {}
        reg = radio.get("data_registration") or "нет ADB-данных"
        rat = radio.get("data_network") or ""
        conn_state = radio.get("data_connection_state")
        conn_text = "данные подключены" if conn_state == 2 else "состояние данных неизвестно" if conn_state is None else f"состояние данных: {conn_state}"
        self.metric_vars["radio"].set(f"{radio.get('operator') or 'Оператор: —'}\n{rat} • {reg}\n{conn_text}")
        self._color_metric("radio", "bad" if radio.get("data_reg_code") not in (None, 0) else "normal")

        rsrp, rsrq, sinr = radio.get("rsrp_dbm"), radio.get("rsrq_db"), radio.get("rssnr_db")
        def fmt(value: Any, suffix: str) -> str:
            return f"{value} {suffix}" if value is not None else "—"
        self.metric_vars["signal"].set(f"RSRP: {fmt(rsrp, 'dBm')}\nRSRQ: {fmt(rsrq, 'dB')} • RSSNR: {fmt(sinr, 'dB')}\nКанал: {fmt(radio.get('lte_channel'), '')} • PCI: {fmt(radio.get('physical_cell_id'), '')}")
        poor = (rsrp is not None and rsrp <= -115) or (rsrq is not None and rsrq <= -17) or (sinr is not None and sinr < 0)
        very_poor = (rsrp is not None and rsrp <= -120) or (rsrq is not None and rsrq <= -20) or (sinr is not None and sinr < -3)
        self._color_metric("signal", "bad" if very_poor else "warn" if poor else "normal")

        dl_est, ul_est = radio.get("downlink_est_kbps"), radio.get("uplink_est_kbps")
        capacity = f"Модем est.: ↓ {dl_est if dl_est is not None else '—'} / ↑ {ul_est if ul_est is not None else '—'} kbit/s\n"
        capacity += f"ADB: {radio.get('adb_status') or 'нет данных'}\n"
        capacity += f"Замер радио: {sample.get('radio_age', '—')} сек назад"
        self.metric_vars["capacity"].set(capacity)
        self._color_metric("capacity", "normal" if "подключён" in (radio.get("adb_status") or "") else "warn")

    def _color_metric(self, key: str, severity: str) -> None:
        label = getattr(self, f"{key}_label")
        colors = {"normal": "#182230", "warn": "#b54708", "bad": "#b42318"}
        label.configure(fg=colors.get(severity, colors["normal"]))

    def _status_event(self, event: dict[str, Any]) -> None:
        status = event.get("status", "НОРМА")
        details = event.get("details", [])
        text = f"{event.get('time', '')}  {status}: " + ("; ".join(details) if details else "сеть восстановилась")
        self._event(text, "bad" if status == "СБОЙ" else "warn" if status == "НЕСТАБИЛЬНО" else "good")

    def _event(self, text: str, tag: str = "") -> None:
        if not hasattr(self, "events_text"):
            return
        self.events_text.configure(state="normal")
        self.events_text.insert("end", text + "\n", tag)
        line_count = int(self.events_text.index("end-1c").split(".")[0])
        if line_count > 80:
            self.events_text.delete("1.0", f"{line_count - 80}.0")
        self.events_text.see("end")
        self.events_text.configure(state="disabled")

    def _set_attention(self, active: bool) -> None:
        if active == self.attention_active:
            return
        self.attention_active = active
        try:
            self.root.title(self.alert_window_title if active else self.base_window_title)
        except tk.TclError:
            return

        if os.name != "nt":
            return
        try:
            class FlashWindowInfo(ctypes.Structure):
                _fields_ = [
                    ("cbSize", wintypes.UINT),
                    ("hwnd", wintypes.HWND),
                    ("dwFlags", wintypes.DWORD),
                    ("uCount", wintypes.UINT),
                    ("dwTimeout", wintypes.DWORD),
                ]

            user32 = ctypes.WinDLL("user32", use_last_error=True)
            user32.GetAncestor.argtypes = [wintypes.HWND, wintypes.UINT]
            user32.GetAncestor.restype = wintypes.HWND
            user32.FlashWindowEx.argtypes = [ctypes.POINTER(FlashWindowInfo)]
            user32.FlashWindowEx.restype = wintypes.BOOL

            hwnd = wintypes.HWND(self.root.winfo_id())
            top_level_hwnd = user32.GetAncestor(hwnd, 2)  # GA_ROOT
            if top_level_hwnd:
                hwnd = top_level_hwnd
            flags = 0x00000002 | 0x00000004 if active else 0x00000000  # TRAY | TIMER / STOP
            info = FlashWindowInfo(ctypes.sizeof(FlashWindowInfo), hwnd, flags, 0, 0)
            user32.FlashWindowEx(ctypes.byref(info))
        except (AttributeError, OSError, OverflowError, tk.TclError):
            pass

    def open_log_folder(self) -> None:
        if not self.run_dir:
            messagebox.showinfo("Папка журнала", "Сначала начните сбор.")
            return
        try:
            os.startfile(str(self.run_dir))
        except (AttributeError, OSError) as exc:
            messagebox.showerror("Не удалось открыть папку", str(exc))

    def close(self) -> None:
        self.stop_event.set()
        self.running = False
        self._set_attention(False)
        self.root.destroy()


def main() -> None:
    root = tk.Tk()
    VodafoneMonitor(root)
    root.mainloop()


if __name__ == "__main__":
    main()

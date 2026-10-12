from __future__ import annotations

import argparse
import ctypes
import json
import logging
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable, Iterable

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

# Coordinar UIA y SendInput en píxeles físicos incluso con varios monitores.
try:
    ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
except Exception:
    pass

from pywinauto import Desktop, keyboard, mouse
import win32con
import win32gui
import win32process
import win32api
from PIL import ImageGrab
from pywinauto.timings import TimeoutError as PwaTimeoutError


APP_NAME = "QooCam VR180 Batch AntiShake"
APP_VERSION = "1.8.0"
QOOCAM_EXE: Path | None = None
DEFAULT_SOURCE = Path(r"G:\243 - Ari Cumback\100QOOCAM")
DEFAULT_OUTPUT_NAME = "QooCam_180_3D_Normal_AntiShake_HQ"
IGNORED_SOURCE_DIRS = {
    DEFAULT_OUTPUT_NAME.casefold(),
    "QooCamAutomation_Test".casefold(),
    "KDOutput".casefold(),
    "Proxies".casefold(),
    "Right25".casefold(),
    "_HISTORICO".casefold(),
}
MODE_NAME = "180 3D Normal"
EXPORT_SETTINGS = {
    "mode": MODE_NAME, "resolution": "7680x3840", "format": "MP4(H265)",
    "bitrate": "High", "stabilization": "Anti-shake", "audio": "Stereo Audio",
    "linked_segments": "Single Import",
}
VIDEO_RE = re.compile(
    r"^(?P<prefix>Q360_\d{8}_\d{6})_(?P<part>\d{6})\.MP4$", re.IGNORECASE
)
GENERATED_VIDEO_RE = re.compile(r"(?:_output|_reframe|_proxy)(?:\(\d+\))?\.mp4$", re.IGNORECASE)


def app_data_dir() -> Path:
    root = Path(os.environ.get("LOCALAPPDATA", Path.home()))
    path = root / "QooCamBatchAntiShake"
    path.mkdir(parents=True, exist_ok=True)
    return path


LOG_PATH = app_data_dir() / "automator.log"
logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    encoding="utf-8",
)


@dataclass(frozen=True)
class RecordingGroup:
    key: str
    files: tuple[Path, ...]

    @property
    def representative(self) -> Path:
        return self.files[0]

    @property
    def expected_output_name(self) -> str:
        return f"{self.representative.stem}_Output.mp4"

    def signature(self) -> list[dict[str, int | str]]:
        return [
            {
                "name": f.name,
                "size": f.stat().st_size,
                "mtime_ns": f.stat().st_mtime_ns,
            }
            for f in self.files
        ]


class AutomationError(RuntimeError):
    pass


class CancelledError(AutomationError):
    pass


class StepPausedError(AutomationError):
    """Pausa de seguridad: no debe causar un reinicio del proyecto."""
    pass


def is_original_video(name: str) -> bool:
    # Importar todos los MP4 de la carpeta, incluidos originales renombrados.
    # Excluir las salidas habituales para evitar volver a procesarlas.
    return Path(name).suffix.casefold() == ".mp4" and not GENERATED_VIDEO_RE.search(name)


def find_qoocam_exe(explicit: Path | None = None) -> Path:
    """Resolver QooCam por argumento, variable local o ubicaciones habituales."""
    candidates: list[Path] = []
    if explicit:
        candidates.append(explicit.expanduser())
    configured = os.environ.get("QOOCAM_STUDIO_EXE", "").strip().strip('"')
    if configured:
        candidates.append(Path(configured).expanduser())
    for env_name in ("ProgramFiles(x86)", "ProgramFiles", "LOCALAPPDATA"):
        root = os.environ.get(env_name)
        if root:
            candidates.extend([
                Path(root) / "QooCamStudio" / "QooCamStudio.exe",
                Path(root) / "Kandao" / "QooCamStudio" / "QooCamStudio.exe",
            ])
    checked: list[str] = []
    for candidate in candidates:
        candidate = candidate.resolve()
        checked.append(str(candidate))
        if candidate.is_file():
            return candidate
    raise AutomationError(
        "No se encontró QooCam Studio. Instálalo o indica su ejecutable con "
        "--qoocam-exe. Rutas comprobadas: " + "; ".join(checked)
    )


def scan_recordings(source: Path) -> list[RecordingGroup]:
    if not source.is_dir():
        raise AutomationError(f"La carpeta de entrada no existe: {source}")

    return [RecordingGroup(path.stem, (path,))
            for path in sorted(source.iterdir(), key=lambda p: p.name.casefold())
            if path.is_file() and is_original_video(path.name)]


def human_size(size: int) -> str:
    value = float(size)
    for suffix in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or suffix == "TB":
            return f"{value:.2f} {suffix}"
        value /= 1024
    return f"{size} B"


def discover_jobs(
    sources: Iterable[Path], output: Path | None = None, *, recursive: bool = True
):
    """Buscar entradas sin seguir enlaces ni confundir resultados con originales."""
    folders: dict[str, Path] = {}
    if output is not None:
        output = output.expanduser().resolve()
    for source in sources:
        source = source.expanduser().resolve()
        if not source.is_dir():
            raise AutomationError(f"La carpeta de entrada no existe: {source}")
        for directory, children, files in os.walk(source, followlinks=False):
            children[:] = sorted(
                name for name in children if name.casefold() not in IGNORED_SOURCE_DIRS
            ) if recursive else []
            parent = Path(directory)
            if output and parent == output.expanduser().resolve():
                children[:] = []
                continue
            if any(is_original_video(name) for name in files):
                folders[os.path.normcase(str(parent))] = parent
    if output and len(folders) > 1:
        raise AutomationError(
            "Hay videos en varias carpetas. Deja la salida vacía para guardar "
            "cada lote junto a sus originales, sin mezclar nombres."
        )
    return [(folder, output or folder / DEFAULT_OUTPUT_NAME)
            for _, folder in sorted(folders.items())]


def job_report(source: Path, output: Path) -> dict:
    manifest = read_manifest(output)
    groups = scan_recordings(source)
    return {
        "source": str(source), "output": str(output),
        "groups": [{"key": group.key,
                    "files": [str(path) for path in group.files],
                    "expected_output": group.expected_output_name,
                    "state": "completed" if is_completed(group, output, manifest)
                    else "existing_unverified" if (output / group.expected_output_name).exists()
                    else "pending"} for group in groups],
    }


def read_manifest(output: Path) -> dict:
    manifest = output / "qcam_batch_manifest.json"
    if not manifest.exists():
        return {"version": 1, "completed": {}}
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
        if not isinstance(data.get("completed"), dict):
            raise ValueError("completed no es un objeto")
        return data
    except Exception:
        logging.exception("No se pudo leer el manifiesto %s", manifest)
        return {"version": 1, "completed": {}}


def write_manifest(output: Path, data: dict) -> None:
    path = output / "qcam_batch_manifest.json"
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temp, path)


def validate_existing_render(path: Path) -> bool:
    """Aceptar una salida heredada solo si coincide con el perfil final esperado."""
    ffprobe = shutil.which("ffprobe")
    if not ffprobe or not path.is_file() or path.stat().st_size <= 1_000_000:
        return False
    result = subprocess.run(
        [
            ffprobe, "-v", "error", "-show_entries",
            "stream=codec_type,codec_name,width,height,channels:format=duration",
            "-of", "json", str(path),
        ],
        capture_output=True, text=True, encoding="utf-8", errors="ignore",
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), check=False,
    )
    if result.returncode != 0:
        return False
    try:
        data = json.loads(result.stdout)
        streams = data.get("streams", [])
        video = next(stream for stream in streams if stream.get("codec_type") == "video")
        audios = [stream for stream in streams if stream.get("codec_type") == "audio"]
        duration = float(data.get("format", {}).get("duration", 0))
        return (
            video.get("codec_name") in {"hevc", "h265"}
            and int(video.get("width", 0)) == 7680
            and int(video.get("height", 0)) == 3840
            and duration > 0
            and (not audios or int(audios[0].get("channels", 0)) == 2)
        )
    except (KeyError, StopIteration, TypeError, ValueError, json.JSONDecodeError):
        return False


def adopt_existing_outputs(jobs) -> int:
    """Registrar renders heredados válidos sin volver a procesarlos."""
    adopted = 0
    for source, output in jobs:
        manifest = read_manifest(output)
        completed = manifest.setdefault("completed", {})
        changed = False
        for group in scan_recordings(source):
            existing = output / group.expected_output_name
            if group.key in completed or not existing.exists():
                continue
            if validate_existing_render(existing):
                completed[group.key] = {
                    "sources": group.signature(),
                    "output": existing.name,
                    "output_size": existing.stat().st_size,
                    "completed_at": datetime.now().astimezone().isoformat(),
                    "adopted_existing": True,
                    "settings": dict(EXPORT_SETTINGS),
                }
                adopted += 1
                changed = True
        if changed:
            manifest["app_version"] = APP_VERSION
            write_manifest(output, manifest)
    return adopted


def is_completed(group: RecordingGroup, output: Path, manifest: dict) -> bool:
    record = manifest.get("completed", {}).get(group.key)
    if not record or record.get("sources") != group.signature():
        return False
    if record.get("settings") != EXPORT_SETTINGS:
        return False
    result = output / record.get("output", "")
    return (record.get("output") == group.expected_output_name
            and result.is_file() and result.stat().st_size > 1_000_000
            and result.stat().st_size == record.get("output_size"))


def qcam_is_running() -> bool:
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    result = subprocess.run(
        [
            "tasklist",
            "/FI",
            "IMAGENAME eq QooCamStudio.exe",
            "/FO",
            "CSV",
            "/NH",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="ignore",
        creationflags=creationflags,
        check=False,
    )
    return "QooCamStudio.exe" in result.stdout


def workstation_is_locked() -> bool:
    """LogonUI activo en la sesión interactiva indica pantalla bloqueada."""
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    result = subprocess.run(
        ["tasklist", "/FI", "IMAGENAME eq LogonUI.exe", "/FO", "CSV", "/NH"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="ignore",
        creationflags=creationflags,
        check=False,
    )
    return "LogonUI.exe" in result.stdout


def keep_system_awake(enabled: bool) -> None:
    # ES_CONTINUOUS | ES_SYSTEM_REQUIRED; se restaura con ES_CONTINUOUS.
    flags = 0x80000001 if enabled else 0x80000000
    try:
        ctypes.windll.kernel32.SetThreadExecutionState(flags)
    except Exception:
        logging.exception("No se pudo cambiar el estado de suspensión")


def wait_until(
    predicate: Callable[[], object],
    timeout: float,
    description: str,
    interval: float = 0.5,
    cancel: threading.Event | None = None,
):
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        if cancel and cancel.is_set():
            raise CancelledError("Operación cancelada por el usuario")
        try:
            value = predicate()
            if value:
                return value
        except Exception as exc:
            last_error = exc
        time.sleep(interval)
    extra = f" ({last_error})" if last_error else ""
    raise AutomationError(f"Tiempo agotado esperando: {description}{extra}")


def process_windows(pid: int, backend: str = "uia"):
    desktop = Desktop(backend=backend)
    handles = []
    def collect(handle, _):
        if (win32gui.IsWindowVisible(handle)
                and win32process.GetWindowThreadProcessId(handle)[1] == pid):
            handles.append(handle)
    # Qt Feedback puede faltar en Desktop.windows(process=pid).
    # Obtener HWND reales del proceso antes de consultar sus controles UIA.
    win32gui.EnumWindows(collect, None)
    return [desktop.window(handle=handle) for handle in handles]


def bring_to_front(window) -> None:
    """Pone una ventana Qt delante antes de enviar clics físicos."""
    handle = window.wrapper_object().handle
    win32gui.ShowWindow(handle, win32con.SW_RESTORE)
    flags = win32con.SWP_NOMOVE | win32con.SWP_NOSIZE | win32con.SWP_SHOWWINDOW
    win32gui.SetWindowPos(handle, win32con.HWND_TOPMOST, 0, 0, 0, 0, flags)
    win32gui.SetWindowPos(handle, win32con.HWND_NOTOPMOST, 0, 0, 0, 0, flags)
    window.set_focus()
    time.sleep(0.35)


def prepare_editor(window) -> None:
    """Ventana física estable: evita posiciones dependientes de maximizado/DPI."""
    bring_to_front(window)
    handle = window.wrapper_object().handle
    win32gui.ShowWindow(handle, win32con.SW_RESTORE)
    monitor = win32api.GetMonitorInfo(win32api.MonitorFromWindow(handle))['Work']
    left, top, right, bottom = monitor
    width, height = min(1600, right-left-40), min(1000, bottom-top-40)
    win32gui.MoveWindow(handle, left+(right-left-width)//2,
                        top+(bottom-top-height)//2, width, height, True)
    time.sleep(0.5)


def menu_photo(window, label):
    folder = app_data_dir() / "screenshots"
    folder.mkdir(exist_ok=True)
    rect = win32gui.GetWindowRect(window.wrapper_object().handle)
    ImageGrab.grab(bbox=rect, all_screens=True).save(folder / f"{label}.png")


def physical_move(coords):
    # Evitar la renormalización de pywinauto a la pantalla primaria: con varios
    # monitores puede desplazar el cursor fuera del menú recién abierto.
    if not ctypes.windll.user32.SetCursorPos(*coords):
        raise AutomationError("No se pudo situar el ratón en el menú")
    time.sleep(0.1)
    actual = win32api.GetCursorPos()
    target = win32gui.WindowFromPoint(actual)
    logging.info("Mouse solicitado=%s real=%s hwnd=%s clase=%s foco=%s", coords, actual,
                 target, win32gui.GetClassName(target), win32gui.GetForegroundWindow())
    if actual != coords:
        raise StepPausedError(f"El cursor no llegó al destino: esperado {coords}, real {actual}")


def physical_click(coords):
    physical_move(coords)
    time.sleep(0.2)
    ctypes.windll.user32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.08)
    ctypes.windll.user32.mouse_event(0x0004, 0, 0, 0, 0)


def menu_already_open(shell):
    pid = win32process.GetWindowThreadProcessId(shell.wrapper_object().handle)[1]
    return find_named_menu_item(pid, "2D / 3D Switch") is not None


def find_named_menu_item(pid, title):
    matches = []
    for window in process_windows(pid):
        if "Popup" not in win32gui.GetClassName(window.wrapper_object().handle):
            continue
        matches.extend(item for item in window.descendants(control_type="MenuItem")
                       if item.window_text() == title and item.is_visible())
    unique = {}
    for item in matches:
        rect = item.rectangle()
        unique[(item.window_text(), rect.left, rect.top, rect.right, rect.bottom)] = item
    return next(iter(unique.values())) if len(unique) == 1 else None


def find_main_window(pid: int):
    for window in process_windows(pid, "uia"):
        rect = window.rectangle()
        if rect.width() < 1000 or rect.height() < 600:
            continue
        try:
            if window.child_window(
                auto_id="MainWindow.container.ImportWidget.toolBarWidget.importBtn"
            ).exists(timeout=0.1):
                return window
        except Exception:
            continue
    return None


def find_shell_window(pid: int):
    for window in process_windows(pid, "uia"):
        rect = window.rectangle()
        if rect.width() < 900 or rect.height() < 500:
            continue
        try:
            menu = window.child_window(
                auto_id="MainWindow.mainTitleBar.mainwindowTitleBarContainer.menuBtn"
            )
            if menu.exists(timeout=0.1) and menu.is_visible():
                return window
        except Exception:
            continue
    return None


def find_project_window(pid: int):
    for window in process_windows(pid, "uia"):
        try:
            button = window.child_window(
                auto_id="ProjectWidget.projectContainer.newProjectWidget.newProjectBtn"
            )
            if button.exists(timeout=0.1) and button.is_visible():
                return window
        except Exception:
            continue
    return None


def close_feedback_if_present(pid: int) -> bool:
    for window in process_windows(pid, "uia"):
        if window.window_text().strip().lower() != "feedback":
            continue
        checks = [control for control in window.descendants(control_type="CheckBox")
                  if control.window_text().strip().lower() == "send error report"]
        sends = [control for control in window.descendants(control_type="Button")
                 if control.window_text().strip().lower() == "send"]
        if len(checks) != 1 or len(sends) != 1:
            logging.warning("Feedback: controles no reconocidos: %s", [
                (control.element_info.control_type, control.window_text(),
                 control.element_info.automation_id) for control in window.descendants()
            ])
            return False
        checkbox, send = checks[0], sends[0]
        if checkbox.get_toggle_state() != 0:
            checkbox.toggle()
        if checkbox.get_toggle_state() != 0:
            raise AutomationError("No pude desmarcar Send error report; no se pulsará Send")
        logging.info("Feedback: Send error report verificado desmarcado; pulsando Send")
        bring_to_front(window)
        send.click_input()
        return True
    return False


def find_common_dialog(pid: int, title_exclude: str | None = None):
    candidates = []
    for window in process_windows(pid, "win32"):
        try:
            if window.class_name() != "#32770" or not window.is_visible():
                continue
            title = window.window_text()
            if title_exclude and title_exclude.lower() in title.lower():
                continue
            candidates.append(window)
        except Exception:
            continue
    if not candidates:
        return None
    return max(candidates, key=lambda w: w.rectangle().width() * w.rectangle().height())


class QooCamAutomator:
    def __init__(
        self,
        source: Path,
        output: Path,
        status: Callable[[str], None],
        cancel: threading.Event,
    ) -> None:
        self.source = source
        self.output = output
        self.status = status
        self.cancel = cancel
        self.process: subprocess.Popen | None = None
        self.main = None
        self.render_log_path: Path | None = None
        self.render_log_offset = 0
        self.render_started = False
        self.project_created = False
        self.antishake_verified = ()
        self.groups = scan_recordings(source)
        self.manifest = read_manifest(output)
        self.pending = [
            group for group in self.groups if not is_completed(group, output, self.manifest)
        ]
        completed_records = self.manifest.get("completed", {})
        self.stale_outputs = [
            group for group in self.pending
            if (output / group.expected_output_name).exists()
            and group.key in completed_records
        ]
        conflicts = [
            group.expected_output_name for group in self.pending
            if (output / group.expected_output_name).exists()
            and group.key not in completed_records
        ]
        if conflicts:
            raise AutomationError(
                "Hay salidas existentes sin verificación de estos ajustes; no se "
                "sobrescribirán: " + ", ".join(conflicts)
            )

    def run(self) -> None:
        global QOOCAM_EXE
        if not self.groups:
            raise AutomationError("No encontré videos MP4 originales en la carpeta")
        self.output.mkdir(parents=True, exist_ok=True)

        if self.stale_outputs:
            history = (
                self.output.parent / "_HISTORICO"
                / ("QooCamRenders_" + datetime.now().strftime("%Y%m%d_%H%M%S"))
            )
            history.mkdir(parents=True, exist_ok=True)
            completed = self.manifest.setdefault("completed", {})
            for group in self.stale_outputs:
                previous = self.output / group.expected_output_name
                os.replace(previous, history / previous.name)
                completed.pop(group.key, None)
            write_manifest(self.output, self.manifest)
            self.status(
                f"Se archivaron {len(self.stale_outputs)} render(s) anteriores porque "
                "el original o la configuración cambió."
            )

        if not self.pending:
            self.status("Todo ya estaba procesado; no hay trabajos pendientes.")
            return
        if QOOCAM_EXE is None:
            QOOCAM_EXE = find_qoocam_exe()
        if not QOOCAM_EXE.is_file():
            raise AutomationError("No se encontró una instalación válida de QooCam Studio")
        if workstation_is_locked():
            raise AutomationError(
                "Windows está bloqueado. Desbloquea la sesión y vuelve a iniciar; "
                "puedes bloquearla otra vez cuando el programa indique ‘Render iniciado’."
            )
        if qcam_is_running():
            raise AutomationError(
                "QooCam Studio ya está abierto. Ciérralo y vuelve a iniciar el proceso "
                "para proteger cualquier proyecto que tengas abierto."
            )

        last_error: Exception | None = None
        for attempt in range(1, 5):
            try:
                self.status(
                    f"Configurando QooCam (intento {attempt}/4): "
                    f"{len(self.pending)} grabación(es), "
                    f"{sum(len(g.files) for g in self.pending)} segmento(s)."
                )
                pid = self.launch_qcam()
                if not self.project_created:
                    self.create_new_project(pid)
                else:
                    self.open_latest_project(pid)

                self.main = wait_until(
                    lambda: find_main_window(pid),
                    45,
                    "el proyecto de QooCam",
                    cancel=self.cancel,
                )
                if self.media_count() == 0:
                    self.import_recordings(pid)
                else:
                    self.status("Proyecto recuperado: los videos importados siguen allí.")

                pid = self.force_180_3d_normal(pid)
                self.open_latest_project(pid)
                self.main = wait_until(
                    lambda: find_main_window(pid),
                    45,
                    "el proyecto creado con los videos",
                    cancel=self.cancel,
                )
                if self.media_count() == 0:
                    raise AutomationError(
                        "El proyecto reabierto no contiene los videos; se reintentará"
                    )
                self.verify_vr180_mode()
                self.apply_antishake()
                self.configure_export(pid)
                break
            except CancelledError:
                raise
            except StepPausedError:
                self.status("PAUSADO: paso no confirmado. Revisa la captura antes de reanudar.")
                raise
            except Exception as exc:
                last_error = exc
                logging.error(
                    "Fallo de configuración intento %s: %s\n%s",
                    attempt,
                    exc,
                    traceback.format_exc(),
                )
                if self.render_started or attempt == 4:
                    raise
                if self.process is not None and self.process.poll() is None:
                    raise StepPausedError(
                        f"QooCam sigue abierto, pero el paso falló: {exc}. "
                        "No se reiniciará ni se repetirá el flujo completo."
                    ) from exc
                self.status(
                    f"QooCam se interrumpió durante la configuración ({exc}). "
                    "Reiniciando y recuperando el proyecto…"
                )
                self.restart_after_configuration_failure()
        else:
            raise AutomationError(f"No se pudo configurar QooCam: {last_error}")

        self.monitor_render(pid)

    def create_new_project(self, pid: int) -> None:
        project = find_project_window(pid)
        if project is None:
            return
        self.status("Creando el proyecto nuevo que contendrá los videos…")
        bring_to_front(project)
        project.child_window(
            auto_id="ProjectWidget.projectContainer.newProjectWidget.newProjectBtn"
        ).click_input()
        wait_until(
            lambda: find_main_window(pid),
            30,
            "el proyecto nuevo de QooCam",
            cancel=self.cancel,
        )
        self.project_created = True

    def media_count(self) -> int:
        if self.main is None:
            return 0
        try:
            return len(
                self.main.child_window(
                    auto_id="MainWindow.container.ImportWidget.fileListWidget"
                ).descendants(control_type="ListItem")
            )
        except Exception:
            return 0

    def restart_after_configuration_failure(self) -> None:
        self.main = None
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        self.process = None
        time.sleep(1)

    def launch_qcam(self) -> int:
        self.process = subprocess.Popen(
            [str(QOOCAM_EXE)],
            cwd=str(QOOCAM_EXE.parent),
            creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0),
        )
        pid = self.process.pid

        def startup_ready():
            if self.process.poll() is not None:
                raise StepPausedError("QooCam se cerró durante el inicio")
            if close_feedback_if_present(pid):
                self.status("Reporte desmarcado y Send pulsado; esperando el inicio de QooCam…")
            return find_project_window(pid) or find_main_window(pid)

        wait_until(
            startup_ready,
            40,
            "el inicio de QooCam Studio",
            cancel=self.cancel,
        )
        return pid

    def visual_menu_action(self, shell, name, *, hover=False, timeout=8):
        titles = {"switch": "2D / 3D Switch", "normal": "180 3D Normal",
                  "file": "File", "home": "Home"}
        pid = win32process.GetWindowThreadProcessId(shell.wrapper_object().handle)[1]
        try:
            item = wait_until(lambda: find_named_menu_item(pid, titles[name]), timeout,
                              f"opción exacta {titles[name]}", cancel=self.cancel)
        except CancelledError:
            raise
        except AutomationError as exc:
            menu_photo(shell, f"PAUSADO-{name}")
            raise StepPausedError(f"No apareció la opción exacta '{titles[name]}'") from exc
        self.status(f"Seleccionando control confirmado: {item.window_text()}")
        if self.cancel.is_set():
            raise CancelledError("Operación cancelada")
        if name in {"switch", "file"}:
            item.expand()
            logging.info("Expanded %s state %s", name, item.get_expand_state())
        else:
            # Invoke de Qt puede bloquear UI Automation mientras está abierto
            # el diálogo modal. El clic usa la geometría del control por nombre.
            item.click_input()
        time.sleep(1.5)
        for popup in process_windows(pid):
            logging.info("Después de %s: %s %s", name, popup.window_text(),
                         [(c.element_info.control_type, c.window_text()) for c in popup.descendants(control_type="MenuItem")])

    def force_180_3d_normal(self, pid: int) -> int:
        """Selecciona Normal (nunca Reverse) y reinicia si QooCam lo solicita."""
        self.status("Fijando el modo 180 3D Normal (nunca Reverse)…")
        shell = wait_until(
            lambda: find_shell_window(pid),
            30,
            "el menú principal de QooCam",
            cancel=self.cancel,
        )
        prepare_editor(shell)
        self.status("Esperando a que el visor termine de cargar antes de abrir Menu…")
        wait_until(
            lambda: any(control.window_text() in {"Panorama", "VR180"}
                        and control.is_visible() for control in shell.descendants()),
            60, "el visor cargado (Panorama o VR180)", cancel=self.cancel,
        )
        # El texto aparece antes de que Qt termine de reconstruir el editor.
        time.sleep(3)
        menu_button = shell.child_window(
            auto_id="MainWindow.mainTitleBar.mainwindowTitleBarContainer.menuBtn"
        )
        button_rect = menu_button.rectangle()
        if not menu_already_open(shell):
            physical_click((button_rect.left + button_rect.width() // 2,
                            button_rect.top + button_rect.height() // 2))
        time.sleep(2.5)
        menu_photo(shell, "01-menu")
        # Menú verificado en QooCam Studio 3.3.0.18:
        # File, 2D/3D Switch -> 360 2D, 180 3D Normal, 180 3D Reverse.
        # Los menús Qt se consultan en sus ventanas Popup, por nombre exacto.
        menu_rect = menu_button.rectangle()
        logging.info("Menu rect UIA: %s; ventana física: %s", menu_rect,
                     win32gui.GetWindowRect(shell.wrapper_object().handle))
        self.visual_menu_action(shell, "switch")
        menu_photo(shell, "02-switch")
        self.visual_menu_action(shell, "normal")
        menu_photo(shell, "03-normal-seleccionado")
        time.sleep(2)
        menu_photo(shell, "03-normal")

        def restart_prompt():
            for window in process_windows(pid, "uia"):
                try:
                    message = window.child_window(
                        title_re=r".*restart QooCam Studio.*", control_type="Text"
                    )
                    ok = window.child_window(title="OK", control_type="Button")
                    if message.exists(timeout=0.1) and ok.exists(timeout=0.1):
                        return window
                except Exception:
                    continue
            return None

        try:
            prompt = wait_until(
                restart_prompt,
                20,
                "el aviso de reinicio",
                interval=0.25,
                cancel=self.cancel,
            )
        except CancelledError:
            raise
        except AutomationError:
            prompt = None

        if prompt is None:
            # No avanzar por una selección no confirmada. Si ya era VR180,
            # QooCam puede omitir el aviso; comprobarlo explícitamente.
            marker = shell.child_window(title="VR180", control_type="Text")
            if marker.exists(timeout=0.5) and marker.is_visible():
                self.status("VR180 ya estaba activo; continuando con el proyecto.")
                return pid
            # Repetir sólo ESTE clic si Normal continúa visible, no el flujo.
            self.status("Sin aviso: reintentando una vez el clic en Normal, con una nueva captura…")
            self.visual_menu_action(shell, "normal", timeout=5)
            try:
                prompt = wait_until(restart_prompt, 15, "aviso tras segundo clic en Normal",
                                    cancel=self.cancel)
            except CancelledError:
                raise
            except AutomationError as exc:
                menu_photo(shell, "PAUSADO-normal-sin-aviso")
                raise StepPausedError("Dos intentos sin confirmar el cambio; se pausa aquí") from exc

        prompt.child_window(title="OK", control_type="Button").click_input()
        self.status("Aviso aceptado; esperando que el panel desaparezca…")
        wait_until(lambda: restart_prompt() is None, 30,
                   "la desaparición del aviso de cambio de modo", cancel=self.cancel)
        time.sleep(3)
        # En la grabación el aviso se acepta y se vuelve a File > Home,
        # sin finalizar el proceso. El editor se reconstruye al abrir la tarjeta.
        return pid

    def open_latest_project(self, pid: int) -> None:
        project = find_project_window(pid)
        if project is None:
            self.status("Volviendo a File > Home para reabrir el proyecto por su fecha…")
            shell = wait_until(
                lambda: find_shell_window(pid),
                20,
                "la ventana de QooCam",
                cancel=self.cancel,
            )
            prepare_editor(shell)
            menu_button = shell.child_window(
                auto_id="MainWindow.mainTitleBar.mainwindowTitleBarContainer.menuBtn"
            )
            button_rect = menu_button.rectangle()
            if not menu_already_open(shell):
                physical_click((button_rect.left + button_rect.width() // 2,
                                button_rect.top + button_rect.height() // 2))
            time.sleep(2.5)
            # Consultar también las ventanas Popup de Qt para File > Home.
            menu_rect = menu_button.rectangle()
            self.visual_menu_action(shell, "file", hover=True)
            self.visual_menu_action(shell, "home")
            try:
                project = wait_until(lambda: find_project_window(pid), 20,
                                     "File > Home", cancel=self.cancel)
            except CancelledError:
                raise
            except AutomationError:
                self.status("Home no abrió: reintentando sólo ese clic una vez…")
                self.visual_menu_action(shell, "home", timeout=5)
                try:
                    project = wait_until(lambda: find_project_window(pid), 20,
                                         "Home tras segundo clic", cancel=self.cancel)
                except CancelledError:
                    raise
                except AutomationError as exc:
                    menu_photo(shell, "PAUSADO-home")
                    raise StepPausedError("Home no confirmó el cambio; flujo pausado") from exc

        self.status("Abriendo el proyecto recién creado (el primero por fecha)…")
        bring_to_front(project)
        project_list = project.child_window(
            auto_id="ProjectWidget.projectContainer.existProjectWidget.listWidget"
        )
        wait_until(
            lambda: project_list.exists(timeout=0.1),
            20,
            "la lista de proyectos por fecha",
            cancel=self.cancel,
        )
        items = project_list.descendants(control_type="ListItem")
        if items:
            first = min(items, key=lambda item: (item.rectangle().top, item.rectangle().left))
            first.click_input(double=True)
        else:
            # Las tarjetas Qt no exponen ListItem en QooCam 3.3.0.18. La más
            # reciente aparece siempre primero, a la izquierda de la lista.
            rect = project_list.rectangle()
            mouse.double_click(coords=(rect.left + 76, rect.top + 80))
        wait_until(
            lambda: find_main_window(pid),
            30,
            "la apertura del proyecto por fecha",
            cancel=self.cancel,
        )

    def import_recordings(self, pid: int) -> None:
        assert self.main is not None
        self.status("Importando cada archivo por separado: Single Import, nunca Merge…")
        bring_to_front(self.main)
        self.main.child_window(
            auto_id="MainWindow.container.ImportWidget.toolBarWidget.importBtn"
        ).click_input()

        dialog = wait_until(
            lambda: find_common_dialog(pid),
            15,
            "el selector de archivos",
            cancel=self.cancel,
        )
        bring_to_front(dialog)
        edits = dialog.descendants(class_name="Edit")
        if not edits:
            raise AutomationError("No pude localizar el campo de nombre de archivo")
        paths = " ".join(
            f'"{path}"' for group in self.pending for path in group.files
        )
        edits[0].set_edit_text(paths)
        open_button = dialog.child_window(title="&Abrir", class_name="Button")
        if not open_button.exists(timeout=1):
            open_button = dialog.child_window(control_id=1, class_name="Button")
        open_button.click_input()

        def link_or_loaded():
            if self.main.child_window(
                auto_id=(
                    "MainWindow.container.ImportWidget.MediaLinkDialog.container."
                    "bottomContainer.singleBtn"
                )
            ).exists(timeout=0.1):
                return "linked"
            items = self.main.child_window(
                auto_id="MainWindow.container.ImportWidget.fileListWidget"
            ).descendants(control_type="ListItem")
            expected = sorted(group.representative.name for group in self.pending)
            return "loaded" if sorted(item.window_text() for item in items) == expected else None

        deadline = time.monotonic() + 180
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise StepPausedError("No se confirmó la importación individual de todos los originales")
            state = wait_until(link_or_loaded, remaining, "Single Import o lista completa",
                               interval=1, cancel=self.cancel)
            if state == "loaded":
                break
            checkbox = self.main.child_window(
                auto_id=(
                    "MainWindow.container.ImportWidget.MediaLinkDialog.container."
                    "bottomContainer.checkBox"
                )
            )
            if checkbox.get_toggle_state() == 0:
                checkbox.click_input()
            wait_until(lambda: checkbox.get_toggle_state() == 1, 5,
                       "aplicar Single Import a los demás archivos", cancel=self.cancel)
            self.main.child_window(
                auto_id=(
                    "MainWindow.container.ImportWidget.MediaLinkDialog.container."
                    "bottomContainer.singleBtn"
                )
            ).click_input()

            time.sleep(1)
        self.status(f"Importación confirmada: {len(self.pending)} archivos separados (Single Import).")

    def verify_vr180_mode(self) -> None:
        assert self.main is not None

        def vr180_visible():
            marker = self.main.child_window(title="VR180", control_type="Text")
            return marker.exists(timeout=0.1) and marker.is_visible()

        wait_until(
            vr180_visible,
            45,
            "la vista estereoscópica VR180; se evitó exportar en 360 o Reverse",
            interval=0.5,
            cancel=self.cancel,
        )
        self.status("Modo verificado: visor VR180 estereoscópico activo.")

    def apply_antishake(self) -> None:
        assert self.main is not None
        self.antishake_verified = ()
        self.verify_vr180_mode()
        self.status("Aplicando Anti‑Shake a todas las grabaciones…")
        prepare_editor(self.main)
        media_list = self.main.child_window(
            auto_id="MainWindow.container.ImportWidget.fileListWidget"
        )
        items = media_list.descendants(control_type="ListItem")
        if not items:
            raise AutomationError("QooCam no mostró ningún medio importado")
        stab_button = self.main.child_window(
            auto_id="MainWindow.container.SettingBarClass.content.stabButton"
        )
        stab_list = self.main.child_window(
            auto_id=(
                "MainWindow.container.SettingWidget2Class.stackedWidget."
                "pageStab.listWidget"
            )
        )
        select_all = self.main.child_window(
            auto_id="MainWindow.container.ImportWidget.toolBarWidget2.chkSelAll"
        )
        if select_all.get_toggle_state() != 0:
            select_all.click_input()
        wait_until(lambda: select_all.get_toggle_state() == 0, 5,
                   "selección individual", cancel=self.cancel)
        names = tuple(item.window_text() for item in items)

        def current_items():
            fresh = media_list.descendants(control_type="ListItem")
            if tuple(item.window_text() for item in fresh) != names:
                raise StepPausedError("Cambió la lista de videos; no se exportará")
            return fresh

        def anti_option():
            # Qt 3.3.0.18 no expone el texto de estas filas. En VR180 son
            # exactamente cabecera, separador, Off, Anti-shake (video de referencia).
            # Su SelectionItem sí permite confirmar el estado, sin leer píxeles.
            options = stab_list.descendants(control_type="ListItem")
            if not stab_list.is_visible() or len(options) != 4:
                raise StepPausedError("Panel VR180 inesperado; no se adivinará Anti-shake")
            return options[3]

        def ensure_panel():
            for attempt in range(2):
                if stab_list.exists(timeout=0.1) and stab_list.is_visible():
                    return
                # Consultar de nuevo después de seleccionar el video: Qt puede
                # cerrar el panel al reconstruir el editor o cambiar de medio.
                bring_to_front(self.main)
                stab_button.click_input()
                try:
                    wait_until(lambda: stab_list.exists(timeout=0.1) and stab_list.is_visible(),
                               8, "panel Stabilization abierto", cancel=self.cancel)
                    return
                except CancelledError:
                    raise
                except AutomationError:
                    if attempt:
                        menu_photo(self.main, "PAUSADO-estabilizacion")
                        raise StepPausedError("El panel Stabilization no abrió tras dos intentos")

        def select_clip(index):
            for attempt in range(2):
                item = current_items()[index]
                bounds, viewport = item.rectangle(), media_list.rectangle()
                if bounds.top < viewport.top or bounds.bottom > viewport.bottom:
                    try:
                        item.iface_scroll_item.ScrollIntoView()
                    except Exception:
                        # Qt no siempre ofrece ScrollItem. Navegar dentro de la
                        # lista mueve su scroll, y comprobar el destino otra vez.
                        media_list.set_focus()
                        keyboard.send_keys("{HOME}" + ("{DOWN}" * index), pause=0.1)
                    item = current_items()[index]
                    bounds = item.rectangle()
                    if bounds.top < viewport.top or bounds.bottom > viewport.bottom:
                        raise StepPausedError("El siguiente video aún no está visible en la lista")
                item.click_input()
                try:
                    wait_until(lambda: [i for i, x in enumerate(current_items())
                                        if x.is_selected()] == [index], 5,
                               f"seleccionar solamente el video {index + 1}", cancel=self.cancel)
                    # Dejar terminar el cambio de medio antes de consultar su ajuste.
                    if self.cancel.wait(2):
                        raise CancelledError("Configuración cancelada")
                    ensure_panel()
                    return
                except CancelledError:
                    raise
                except AutomationError:
                    if attempt:
                        raise StepPausedError(f"No se confirmó el video {index + 1}")

        for index, name in enumerate(names):
            self.status(f"Anti-Shake {index + 1}/{len(names)}: {name}")
            select_clip(index)
            for attempt in range(2):
                anti_option().click_input()
                try:
                    wait_until(lambda: anti_option().is_selected(), 8,
                               f"Anti-Shake en el video {index + 1}", cancel=self.cancel)
                    break
                except CancelledError:
                    raise
                except AutomationError:
                    if attempt:
                        raise StepPausedError(f"Anti-Shake no confirmado en {name}")

        # Volver a cada clip comprueba que el ajuste se guardó por video.
        for index, name in enumerate(names):
            select_clip(index)
            if not anti_option().is_selected():
                raise StepPausedError(f"Anti-Shake no persistió en {name}; exportación bloqueada")
        if select_all.get_toggle_state() == 0:
            select_all.click_input()
        wait_until(lambda: all(item.is_selected() for item in current_items()), 5,
                   "seleccionar todos los videos para exportar", cancel=self.cancel)
        self.antishake_verified = names
        self.status(f"Anti-Shake confirmado individualmente en {len(names)} videos.")

    def configure_export(self, pid: int) -> None:
        assert self.main is not None
        names = tuple(item.window_text() for item in self.main.child_window(
            auto_id="MainWindow.container.ImportWidget.fileListWidget"
        ).descendants(control_type="ListItem"))
        expected = tuple(group.representative.name for group in self.pending)
        if (not names or names != self.antishake_verified
                or sorted(names) != sorted(expected)):
            raise StepPausedError("Exportación bloqueada: faltan videos verificados o hay videos ajenos al lote")
        selected = self.main.child_window(
            auto_id="MainWindow.container.ImportWidget.fileListWidget"
        ).descendants(control_type="ListItem")
        if not all(item.is_selected() for item in selected):
            raise StepPausedError("Selecciona todos los videos verificados antes de exportar")
        self.status("Configurando 8K, H.265, bitrate High y audio estéreo…")
        prepare_editor(self.main)
        self.main.child_window(
            auto_id="MainWindow.mainTitleBar.mainwindowTitleBarContainer.expBtn"
        ).click_input()

        base = (
            "MainWindow.OutputSettingDialog.dialog.content.widget.stackedWidget."
            "QooCamVideoOutputSettingPage.container."
        )
        wait_until(
            lambda: self.main.child_window(
                auto_id=base + "resolutionWidget.resolutionSettingCell.resolutionComboBox"
            ).exists(timeout=0.1),
            20,
            "Export Settings",
            cancel=self.cancel,
        )

        combos = {
            "resolutionWidget.resolutionSettingCell.resolutionComboBox": "7680x3840",
            "formatWidget.formatComboBox": "MP4(H265)",
            "bitrateWidget.widget.bitrateComboBox": "High",
            "exportPathWidget.comboBoxPath": "Specified Directory",
            "audioWidget.audioComboBox": "Stereo Audio",
        }
        for suffix, value in combos.items():
            combo = self.main.child_window(auto_id=base + suffix)
            combo.select(value)
            selected = combo.selected_text()
            if selected != value:
                raise AutomationError(
                    f"QooCam no aceptó {value!r}; quedó seleccionado {selected!r}"
                )

        path_button = self.main.child_window(
            auto_id=base + "exportPathWidget.exportPathBtn"
        )
        path_button.click_input()
        folder_dialog = wait_until(
            lambda: find_common_dialog(pid, title_exclude="Select a file"),
            15,
            "el selector de carpeta de salida",
            cancel=self.cancel,
        )
        bring_to_front(folder_dialog)
        folder_edit = folder_dialog.child_window(control_id=1152, class_name="Edit")
        if not folder_edit.exists(timeout=1):
            edits = folder_dialog.descendants(class_name="Edit")
            if not edits:
                raise AutomationError("No pude localizar el campo de carpeta de salida")
            folder_edit = edits[0]
        folder_edit.set_edit_text(str(self.output))
        if folder_edit.window_text().casefold() != str(self.output).casefold():
            raise StepPausedError("El selector no aceptó la carpeta completa de salida")
        folder_dialog.child_window(control_id=1, class_name="Button").click_input()

        expected_path = str(self.output).replace("\\", "/").rstrip("/").casefold()
        label = self.main.child_window(
            auto_id=base + "exportPathWidget.exportPathBtn.container.textLabel"
        )
        wait_until(
            lambda: self.output_label_matches(label.window_text(), expected_path),
            10,
            "la confirmación de la carpeta de salida",
            cancel=self.cancel,
        )

        self.start_export()

    @staticmethod
    def output_label_matches(displayed: str, expected_path: str) -> bool:
        displayed = displayed.replace("\\", "/").rstrip("/").casefold()
        expected_path = expected_path.replace("\\", "/").rstrip("/").casefold()
        if displayed == expected_path:
            return True
        # Qt recorta visualmente QLabel; la carpeta completa ya fue escrita
        # y aceptada en el selector. Confirmar su prefijo mostrado.
        for ending in ("…", "...", "\ufffd"):
            if displayed.endswith(ending):
                prefix = displayed[:-len(ending)]
                return len(prefix) >= 20 and expected_path.startswith(prefix)
        return False

    def start_export(self) -> None:
        assert self.main is not None
        base = ("MainWindow.OutputSettingDialog.dialog.content.widget.stackedWidget."
                "QooCamVideoOutputSettingPage.container.")
        combos = {
            "resolutionWidget.resolutionSettingCell.resolutionComboBox": "7680x3840",
            "formatWidget.formatComboBox": "MP4(H265)",
            "bitrateWidget.widget.bitrateComboBox": "High",
            "exportPathWidget.comboBoxPath": "Specified Directory",
            "audioWidget.audioComboBox": "Stereo Audio",
        }
        self.render_log_path = self.qcam_log_path()
        if self.render_log_path is not None:
            try:
                self.render_log_offset = len(
                    self.render_log_path.read_text(encoding="utf-8", errors="ignore")
                )
            except OSError:
                self.render_log_offset = 0

        if self.cancel.is_set():
            raise CancelledError("Cancelado antes de pulsar Export")
        for suffix, value in combos.items():
            if self.main.child_window(auto_id=base + suffix).selected_text() != value:
                raise StepPausedError("Los ajustes de exportación cambiaron antes de pulsar Export")

        bring_to_front(self.main)
        button = self.main.child_window(auto_id=(
            "MainWindow.OutputSettingDialog.dialog.content.widget.bottomContainer.exportBtn"
        ))
        rect = button.rectangle()
        point = (rect.left + rect.width() // 2, rect.top + rect.height() // 2)
        handle = self.main.wrapper_object().handle
        pid = win32process.GetWindowThreadProcessId(handle)[1]
        hit = win32gui.WindowFromPoint(point)
        if win32process.GetWindowThreadProcessId(hit)[1] != pid:
            raise StepPausedError("Export está cubierto por otra ventana")
        physical_click(point)
        try:
            wait_until(lambda: not button.exists(timeout=0.1) or not button.is_visible(),
                       15, "Export aceptado y panel cerrado", cancel=self.cancel)
        except CancelledError:
            raise
        except AutomationError:
            bring_to_front(self.main)
            rect = button.rectangle()
            point = (rect.left + rect.width() // 2, rect.top + rect.height() // 2)
            if win32process.GetWindowThreadProcessId(win32gui.WindowFromPoint(point))[1] != pid:
                raise StepPausedError("Export está cubierto; se pausa el segundo intento")
            physical_click(point)
            wait_until(lambda: not button.exists(timeout=0.1) or not button.is_visible(),
                       15, "segundo clic en Export", cancel=self.cancel)
        self.render_started = True
        self.status("Export pulsado: esperando confirmación del render de QooCam…")

    def qcam_log_path(self) -> Path | None:
        root = Path(os.environ.get("APPDATA", "")) / "QooCamStudio" / "log" / "QooCamStudio"
        if not root.exists():
            return None
        logs = list(root.rglob("Client-*.log"))
        if not logs:
            return None
        return max(logs, key=lambda path: path.stat().st_mtime_ns)

    def monitor_render(self, pid: int) -> None:
        self.status("Render iniciado. Puedes dejar el programa trabajando.")
        log_path = wait_until(
            lambda: self.render_log_path or self.qcam_log_path(),
            20,
            "el archivo de registro de QooCam",
            cancel=self.cancel,
        )
        expected = len(self.pending)
        expected_tasks = {os.path.normcase(str((self.output / group.expected_output_name).with_suffix('')))
                          for group in self.pending}
        def task_path(value):
            value = value.strip().rstrip('.').replace('/', '\\')
            if value.casefold().endswith('.mp4'):
                value = value[:-4]
            return os.path.normcase(value)
        started: set[str] = set()
        finished: set[str] = set()
        last_size = -1
        last_activity = time.monotonic()
        started_at = time.monotonic()

        while len(finished) < expected:
            if self.cancel.is_set():
                raise CancelledError(
                    "Se detuvo el seguimiento. QooCam puede seguir renderizando en segundo plano."
                )
            if self.process and self.process.poll() is not None:
                raise AutomationError("QooCam Studio se cerró antes de completar los renders")
            if not win32gui.IsWindow(self.main.wrapper_object().handle):
                raise AutomationError("La ventana de QooCam se cerró durante el seguimiento")

            try:
                whole_log = log_path.read_text(encoding="utf-8", errors="ignore")
                text = whole_log[self.render_log_offset :]
            except OSError:
                time.sleep(2)
                continue
            size = len(text)
            if size != last_size:
                last_size = size
                last_activity = time.monotonic()

            for match in re.finditer(r'start render task:([^\"\r\n]+)', text):
                path = task_path(match.group(1))
                if path in expected_tasks:
                    started.add(path)
            for match in re.finditer(r'render task:([^\"\r\n]+)\. normal finished', text):
                path = task_path(match.group(1))
                if path in expected_tasks:
                    finished.add(path)

            if "abnormal finished" in text[-20000:].lower():
                raise AutomationError("QooCam informó que un render terminó de forma anormal")
            if "openvideocodeccontext failed" in text[-20000:].lower():
                raise AutomationError("QooCam no pudo inicializar el codificador de video")

            elapsed = int(time.monotonic() - started_at)
            self.status(
                f"Renderizando: {len(finished)}/{expected} terminados; "
                f"{max(len(started) - len(finished), 0)} activo(s). "
                f"Tiempo: {elapsed // 60:02d}:{elapsed % 60:02d}."
            )
            if time.monotonic() - last_activity > 900:
                raise AutomationError(
                    "QooCam no escribió progreso durante 15 minutos; revisa su ventana"
                )
            self.cancel.wait(5)

        completed = self.manifest.setdefault("completed", {})
        for group in self.pending:
            output_file = self.output / group.expected_output_name
            if not output_file.is_file() or output_file.stat().st_size <= 1_000_000:
                raise AutomationError(
                    f"QooCam reportó éxito, pero falta una salida válida: {output_file.name}"
                )
            completed[group.key] = {
                "sources": group.signature(),
                "output": output_file.name,
                "output_size": output_file.stat().st_size,
                "completed_at": datetime.now().astimezone().isoformat(),
                "settings": dict(EXPORT_SETTINGS),
            }
        self.manifest["app_version"] = APP_VERSION
        write_manifest(self.output, self.manifest)
        self.status(
            f"Completado: {expected} grabación(es) renderizada(s) en {self.output}"
        )


def run_jobs(jobs, status, cancel):
    # Comprobar conflictos en TODOS los lotes antes de iniciar QooCam.
    automators = [QooCamAutomator(source, output, status, cancel)
                  for source, output in jobs]
    if not automators:
        raise AutomationError("No encontré originales MP4 en las entradas ni sus subcarpetas")
    for index, automator in enumerate(automators, 1):
        if cancel.is_set():
            raise CancelledError("Operación cancelada")
        status(f"Carpeta {index}/{len(automators)}: {automator.source}")
        automator.run()
        # Sólo cerrar la instancia propia tras terminar el render de este lote.
        if automator.process is not None and automator.process.poll() is None:
            automator.process.terminate()
            automator.process.wait(timeout=15)


class AutomationIndicator:
    """Visible también para pruebas e invocaciones desde otro programa."""
    def __init__(self, parent, cancel):
        self.cancel = cancel
        self.events = queue.Queue()
        self.window = tk.Toplevel(parent)
        self.window.title("QooCam automático — control del ratón")
        x = max(0, parent.winfo_screenwidth() - 420)
        self.window.geometry(f"390x160+{x}+100")
        self.window.attributes("-topmost", True)
        self.window.configure(bg="#142830")
        self.window.resizable(False, False)
        self.icon = tk.PhotoImage(width=32, height=32)
        self.icon.put("#142830", to=(0, 0, 32, 32))
        self.icon.put("#39d0bc", to=(8, 3, 24, 29))
        self.icon.put("#142830", to=(15, 5, 17, 13))
        self.window.iconphoto(True, self.icon)
        self.heading = tk.Label(self.window, text="● QooCam automático — usando ratón",
                                bg="#142830", fg="#39d0bc", font=("Segoe UI", 11, "bold"))
        self.heading.pack(pady=(10, 4))
        self.detail = tk.Label(self.window, text="Configurando QooCam. No uses el ratón.",
                               bg="#142830", fg="white", wraplength=365)
        self.detail.pack(fill="x", padx=10)
        self.button = ttk.Button(self.window, text="Detener automatización", command=self.stop)
        self.button.pack(pady=10)
        self.window.protocol("WM_DELETE_WINDOW", self.stop)
        self.window.after(100, self.drain)

    def update(self, message):
        self.events.put(("status", message))

    def finish(self, message="Detenido — ya no controla el ratón"):
        self.events.put(("finished", message))

    def stop(self):
        self.cancel.set()
        self.heading.configure(text="● Deteniendo automatización…", fg="#ffca6a")
        self.detail.configure(text="Se detendrá en la próxima comprobación segura. No cierra el render.")
        self.button.configure(state="disabled")

    def drain(self):
        try:
            while True:
                kind, message = self.events.get_nowait()
                self.detail.configure(text=message)
                if kind == "finished":
                    self.heading.configure(text="● QooCam automático — detenido", fg="#bcc6ca")
                    self.button.configure(text="Cerrar indicador", state="normal", command=self.window.destroy)
                    self.window.protocol("WM_DELETE_WINDOW", self.window.destroy)
                elif message.startswith("Renderizando:") or message.startswith("Render iniciado"):
                    self.heading.configure(text="● QooCam — renderizando (sin clics)", fg="#ffca6a")
                else:
                    self.heading.configure(text="● QooCam automático — usando ratón", fg="#39d0bc")
        except queue.Empty:
            pass
        if self.window.winfo_exists():
            self.window.after(100, self.drain)


def run_with_indicator(jobs):
    root = tk.Tk()
    root.withdraw()
    cancel = threading.Event()
    indicator = AutomationIndicator(root, cancel)
    def status(message):
        print(message, flush=True)
        indicator.update(message)
    result = {"code": 0}
    def worker():
        keep_system_awake(True)
        try:
            run_jobs(jobs, status, cancel)
        except Exception as exc:
            result["code"] = 1
            status(str(exc))
        finally:
            keep_system_awake(False)
            indicator.finish()
    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    def poll():
        if not thread.is_alive():
            root.after(1500, root.destroy)
        else:
            root.after(200, poll)
    root.after(200, poll)
    root.mainloop()
    return result["code"]


class AutomatorUI:
    def __init__(self, root: tk.Tk, source: Path | None = None) -> None:
        self.root = root
        self.root.title(f"{APP_NAME} {APP_VERSION}")
        icon_path = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent)) / "qcam.ico"
        if icon_path.exists():
            self.root.iconbitmap(str(icon_path))
        self.root.geometry("820x560")
        self.root.minsize(720, 500)
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()
        self.cancel = threading.Event()
        self.worker: threading.Thread | None = None
        self.root.protocol("WM_DELETE_WINDOW", self.close)

        self.source_var = tk.StringVar(value=str(source) if source else "")
        self.output_var = tk.StringVar(value="")
        self.summary_var = tk.StringVar(value="Pulsa Analizar para revisar la carpeta.")
        self.status_var = tk.StringVar(value="Listo.")
        self.build_ui()
        self.root.after(150, self.drain_events)

    def build_ui(self) -> None:
        frame = ttk.Frame(self.root, padding=18)
        frame.pack(fill="both", expand=True)

        ttk.Label(
            frame,
            text="QooCam VR180 Batch Anti‑Shake",
            font=("Segoe UI", 18, "bold"),
        ).pack(anchor="w")
        ttk.Label(
            frame,
            text=(
                "Activa 180 3D Normal, importa cada video por separado y "
                "exporta automáticamente en 8K, H.265, bitrate High y Anti‑Shake. "
                "Los originales nunca se modifican."
            ),
            wraplength=760,
        ).pack(anchor="w", pady=(4, 18))

        form = ttk.Frame(frame)
        form.pack(fill="x")
        ttk.Label(form, text="Entradas: carpetas separadas por ; (incluye subcarpetas)").grid(row=0, column=0, sticky="w")
        ttk.Entry(form, textvariable=self.source_var).grid(
            row=1, column=0, sticky="ew", padx=(0, 8)
        )
        ttk.Button(form, text="Añadir carpeta…", command=self.browse_source).grid(row=1, column=1)

        ttk.Label(form, text="Salida opcional (vacía: una salida junto a cada carpeta de originales)").grid(
            row=2, column=0, sticky="w", pady=(12, 0)
        )
        ttk.Entry(form, textvariable=self.output_var).grid(
            row=3, column=0, sticky="ew", padx=(0, 8)
        )
        ttk.Button(form, text="Examinar…", command=self.browse_output).grid(row=3, column=1)
        form.columnconfigure(0, weight=1)

        settings = ttk.LabelFrame(frame, text="Configuración de exportación", padding=12)
        settings.pack(fill="x", pady=16)
        ttk.Label(
            settings,
            text=(
                "Modo: 180 3D Normal  •  Resolución: 7680×3840  •  Formato: MP4 H.265\n"
                "Bitrate: High  •  "
                "Estabilización: Anti‑Shake  •  Audio: estéreo  •  Segmentos: separados"
            ),
        ).pack(anchor="w")

        ttk.Label(frame, textvariable=self.summary_var, wraplength=760).pack(
            anchor="w", pady=(0, 10)
        )
        self.progress = ttk.Progressbar(frame, mode="indeterminate")
        self.progress.pack(fill="x", pady=(0, 10))
        ttk.Label(frame, textvariable=self.status_var, wraplength=760).pack(anchor="w")

        buttons = ttk.Frame(frame)
        buttons.pack(fill="x", side="bottom", pady=(18, 0))
        ttk.Button(buttons, text="Analizar", command=self.analyze).pack(side="left")
        self.start_button = ttk.Button(
            buttons, text="Iniciar procesamiento", command=self.start
        )
        self.start_button.pack(side="right")
        self.stop_button = ttk.Button(
            buttons, text="Detener automatización", command=self.stop, state="disabled"
        )
        self.stop_button.pack(side="right", padx=(0, 8))

    def browse_source(self) -> None:
        selected = filedialog.askdirectory()
        if selected:
            entries = [value.strip() for value in self.source_var.get().split(";") if value.strip()]
            if selected not in entries:
                entries.append(selected)
            self.source_var.set("; ".join(entries))
            self.analyze()

    def selected_jobs(self):
        sources = [Path(value.strip()) for value in self.source_var.get().split(";")
                   if value.strip()]
        if not sources:
            raise AutomationError("Añade al menos una carpeta de entrada")
        destination = self.output_var.get().strip()
        return discover_jobs(sources, Path(destination) if destination else None)

    def browse_output(self) -> None:
        selected = filedialog.askdirectory(initialdir=self.output_var.get())
        if selected:
            self.output_var.set(selected)

    def analyze(self) -> None:
        try:
            reports = [job_report(source, output) for source, output in self.selected_jobs()]
            states = [group["state"] for report in reports for group in report["groups"]]
            self.summary_var.set(
                f"{len(reports)} carpetas, {len(states)} videos. "
                f"Pendientes: {states.count('pending')}. Terminados: {states.count('completed')}. "
                f"Existentes sin verificar: {states.count('existing_unverified')}."
            )
        except Exception as exc:
            self.summary_var.set(f"Error: {exc}")

    def start(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        try:
            jobs = self.selected_jobs()
        except Exception as exc:
            messagebox.showerror(APP_NAME, str(exc))
            return
        self.cancel.clear()
        self.indicator = AutomationIndicator(self.root, self.cancel)
        self.start_button.configure(state="disabled")
        self.stop_button.configure(state="normal")
        self.progress.start(10)
        self.worker = threading.Thread(
            target=self.worker_main,
            args=(jobs,),
            daemon=True,
        )
        self.worker.start()

    def worker_main(self, jobs) -> None:
        keep_system_awake(True)
        try:
            run_jobs(jobs, lambda text: self.events.put(("status", text)), self.cancel)
            self.events.put(("done", "\n".join(str(output) for _, output in jobs)))
        except CancelledError as exc:
            self.events.put(("cancelled", str(exc)))
        except Exception as exc:
            logging.error("Fallo: %s\n%s", exc, traceback.format_exc())
            self.events.put(("error", str(exc)))
        finally:
            keep_system_awake(False)

    def stop(self) -> None:
        self.cancel.set()
        self.status_var.set(
            "Deteniendo el seguimiento. QooCam no se cerrará ni se cancelará automáticamente."
        )

    def close(self) -> None:
        if self.worker and self.worker.is_alive():
            self.stop()
            self.root.after(200, self.close)
            return
        self.root.destroy()

    def drain_events(self) -> None:
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "status":
                    self.status_var.set(str(payload))
                    if hasattr(self, "indicator"):
                        self.indicator.update(str(payload))
                elif kind == "done":
                    self.finish_controls()
                    messagebox.showinfo(
                        APP_NAME,
                        f"Procesamiento completado.\n\nResultados:\n{payload}",
                    )
                elif kind == "cancelled":
                    self.finish_controls()
                    messagebox.showwarning(APP_NAME, str(payload))
                elif kind == "error":
                    self.finish_controls()
                    messagebox.showerror(
                        APP_NAME,
                        f"No se pudo completar el proceso:\n\n{payload}\n\nLog:\n{LOG_PATH}",
                    )
        except queue.Empty:
            pass
        self.root.after(150, self.drain_events)

    def finish_controls(self) -> None:
        if hasattr(self, "indicator"):
            self.indicator.finish()
        self.progress.stop()
        self.start_button.configure(state="normal")
        self.stop_button.configure(state="disabled")
        self.analyze()


def parse_args(argv: Iterable[str] | None = None):
    parser = argparse.ArgumentParser(description=APP_NAME)
    parser.add_argument("--source", type=Path, action="append", help="Repetible; busca también en subcarpetas")
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--direct",
        action="store_true",
        help="Procesa solamente los MP4 del nivel directo de cada carpeta de entrada",
    )
    parser.add_argument(
        "--qoocam-exe",
        type=Path,
        help="Ruta a QooCamStudio.exe; si se omite se detecta automáticamente",
    )
    parser.add_argument(
        "--adopt-existing",
        action="store_true",
        help="Registra salidas existentes solo tras verificar HEVC 7680x3840 y audio",
    )
    parser.add_argument("--autostart", action="store_true")
    parser.add_argument("--analyze", action="store_true")
    parser.add_argument("--run", action="store_true", help="Procesar sin interfaz para un integrador")
    args = parser.parse_args(argv)
    if (args.analyze or args.run or args.autostart) and not args.source:
        parser.error("Especifica al menos una carpeta con --source")
    return args


def main() -> int:
    global QOOCAM_EXE
    args = parse_args()
    if args.qoocam_exe:
        QOOCAM_EXE = find_qoocam_exe(args.qoocam_exe)
    sources = args.source or [DEFAULT_SOURCE]
    jobs = discover_jobs(
        sources, args.output, recursive=not args.direct
    ) if args.analyze or args.run else []
    if args.analyze:
        print(
            json.dumps(
                {"jobs": [job_report(source, output) for source, output in jobs]},
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    if args.run:
        if args.adopt_existing:
            adopt_existing_outputs(jobs)
        has_pending = any(
            group["state"] != "completed"
            for source, output in jobs
            for group in job_report(source, output)["groups"]
        )
        if has_pending:
            QOOCAM_EXE = find_qoocam_exe(args.qoocam_exe)
        return run_with_indicator(jobs)

    root = tk.Tk()
    if args.autostart:
        QOOCAM_EXE = find_qoocam_exe(args.qoocam_exe)
    ui = AutomatorUI(root, sources[0] if sources else None)
    ui.source_var.set("; ".join(str(source) for source in sources))
    ui.output_var.set(str(args.output) if args.output else "")
    ui.analyze()
    if args.autostart:
        root.after(500, ui.start)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

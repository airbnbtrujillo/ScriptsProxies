"""Exporta por lotes los .OSV de la DJI Osmo 360 con VR180 Silver Bullet.

El programa no tiene linea de comandos ni expone sus botones a Windows, asi que
se maneja como QooCam: se abre, se coloca la ventana en un tamano fijo y se hace
clic en "+ Add clips..." y en "Export all". La carpeta de salida ("next to
source") y el formato de exportacion son los que el programa ya tiene guardados.

Un clip esta pendiente cuando junto a NOMBRE.OSV no existe NOMBRE_SBS.mp4.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

try:
    ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
except Exception:
    pass

# La salida puede ir a un archivo o a una consola cp1252.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

import win32api
import win32con
import win32gui
import win32process
from PIL import ImageGrab
from pywinauto import Desktop

APP_NAME = "VR180 Silver Bullet Batch"
EXE_NAME = "vr180-gui.exe"
OUTPUT_SUFFIX = "_SBS.mp4"
EXPECTED = {"codec": "hevc", "width": 8192, "height": 4096}
# Un OSV de unos pocos KB es una grabacion fallida: el programa no puede exportarla.
MIN_SOURCE_BYTES = 5 * 2 ** 20
# El exportado 8K pesa algo mas que su original; se exige este margen de espacio libre.
OUTPUT_SIZE_RATIO = 1.3

# Ventana fija para que los dos botones caigan siempre en el mismo sitio (100 % de escala).
WINDOW_SIZE = (1496, 959)
ADD_CLIPS_FROM_TOP_LEFT = (75, 111)        # "+ Add clips..."
EXPORT_ALL_FROM_BOTTOM_RIGHT = (57, 122)   # "Export all (N)"

PROJECT_RE = re.compile(r"^\d{2,3}[\s-]")


def app_data_dir() -> Path:
    path = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "SilverBulletBatch"
    path.mkdir(parents=True, exist_ok=True)
    return path


LOG_PATH = app_data_dir() / "automator.log"
logging.basicConfig(filename=LOG_PATH, level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s", encoding="utf-8")


class AutomationError(RuntimeError):
    pass


def status(message: str) -> None:
    logging.info(message)
    try:
        print(message, flush=True)
    except Exception:
        pass


def find_exe(explicit: Path | None = None) -> Path:
    candidates = [explicit] if explicit else []
    configured = os.environ.get("VR180_SILVER_BULLET_EXE", "").strip().strip('"')
    if configured:
        candidates.append(Path(configured))
    local = os.environ.get("LOCALAPPDATA")
    if local:
        candidates.append(Path(local) / "Programs" / "VR180 Silver Bullet 2.0" / EXE_NAME)
    for candidate in candidates:
        if candidate and candidate.is_file():
            return candidate
    raise AutomationError("No se encontro VR180 Silver Bullet. Indica su ruta con --exe.")


def output_for(source: Path) -> Path:
    return source.with_name(source.stem + OUTPUT_SUFFIX)


def pending_in(folder: Path) -> list[Path]:
    return [f for f in sorted(folder.iterdir(), key=lambda p: p.name.casefold())
            if f.is_file() and f.suffix.casefold() == ".osv" and f.stat().st_size >= MIN_SOURCE_BYTES
            and not output_for(f).exists()]


def check_free_space(clips: list[Path]) -> None:
    by_drive: dict[str, int] = {}
    for clip in clips:
        by_drive[clip.anchor] = by_drive.get(clip.anchor, 0) + clip.stat().st_size
    for drive, size in by_drive.items():
        need = size * OUTPUT_SIZE_RATIO
        free = shutil.disk_usage(drive).free
        if free < need:
            raise AutomationError(
                f"No hay espacio en {drive}: el lote necesita unos {need / 2 ** 30:,.0f} GB y quedan "
                f"{free / 2 ** 30:,.0f} GB. Libera espacio o limita el lote con --source o --limit.")


def discover(sources: list[Path], root: Path | None) -> list[Path]:
    folders: list[Path] = []
    for source in sources:
        source = source.resolve()
        folders.append(source / "CAM_001" if (source / "CAM_001").is_dir() else source)
    if root:
        folders += [p / "CAM_001" for p in sorted(root.iterdir(), key=lambda p: p.name.casefold())
                    if p.is_dir() and PROJECT_RE.match(p.name) and (p / "CAM_001").is_dir()]
    clips: list[Path] = []
    for folder in folders:
        if not folder.is_dir():
            raise AutomationError(f"La carpeta no existe: {folder}")
        clips += pending_in(folder)
    return clips


def probe(path: Path) -> dict:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return {}
    out = subprocess.run(
        [ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=codec_name,width,height,pix_fmt:format=duration", "-of", "json", str(path)],
        capture_output=True, text=True)
    try:
        data = json.loads(out.stdout)
        stream = data["streams"][0]
        return {"codec": stream.get("codec_name"), "width": stream.get("width"), "height": stream.get("height"),
                "pix_fmt": stream.get("pix_fmt"), "duration": float(data["format"].get("duration", 0))}
    except Exception:
        return {}


def is_running() -> bool:
    out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {EXE_NAME}", "/FO", "CSV", "/NH"],
                         capture_output=True, text=True).stdout
    return EXE_NAME.casefold() in out.casefold()


def workstation_is_locked() -> bool:
    return ctypes.windll.user32.GetForegroundWindow() == 0


def screenshot(label: str) -> Path:
    folder = app_data_dir() / "screenshots"
    folder.mkdir(exist_ok=True)
    path = folder / f"{time.strftime('%Y%m%d_%H%M%S')}_{label}.png"
    ImageGrab.grab(all_screens=True).save(path)
    return path


def wait_until(check, timeout: float, what: str, interval: float = 0.5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(interval)
    raise AutomationError(f"No se confirmo: {what}")


def main_window(pid: int):
    found = []

    def collect(handle, _):
        if win32gui.IsWindowVisible(handle) and win32process.GetWindowThreadProcessId(handle)[1] == pid \
                and win32gui.GetWindowText(handle).startswith("VR180 Silver Bullet"):
            found.append(handle)
    win32gui.EnumWindows(collect, None)
    return found[0] if found else None


def file_dialog(pid: int):
    for window in Desktop(backend="win32").windows(class_name="#32770"):
        if window.process_id() == pid and window.is_visible():
            return window
    return None


def accept_dialog(dialog) -> None:
    """Pulsa el boton predeterminado (Abrir) del selector estandar de Windows."""
    for button in dialog.descendants(class_name="Button"):
        if button.control_id() == 1:
            button.click()
            return
    raise AutomationError("El selector de archivos no tiene boton Abrir.")


def place_window(handle) -> tuple[int, int, int, int]:
    win32gui.ShowWindow(handle, win32con.SW_RESTORE)
    work = win32api.GetMonitorInfo(win32api.MonitorFromPoint((0, 0)))["Work"]
    width, height = WINDOW_SIZE
    if work[2] - work[0] < width or work[3] - work[1] < height:
        raise AutomationError("La pantalla principal es mas pequena que la ventana que necesita el programa.")
    win32gui.MoveWindow(handle, work[0] + 40, work[1] + 40, width, height, True)
    time.sleep(1.0)
    rect = win32gui.GetWindowRect(handle)
    if (rect[2] - rect[0], rect[3] - rect[1]) != WINDOW_SIZE:
        raise AutomationError(f"La ventana no acepto el tamano fijo: quedo {rect}")
    return rect


def click(handle, point: tuple[int, int], label: str) -> None:
    try:
        win32gui.SetForegroundWindow(handle)
    except Exception:
        Desktop(backend="win32").window(handle=handle).set_focus()
    time.sleep(0.4)
    ctypes.windll.user32.SetCursorPos(*point)
    time.sleep(0.3)
    hit = win32gui.WindowFromPoint(point)
    if win32process.GetWindowThreadProcessId(hit)[1] != win32process.GetWindowThreadProcessId(handle)[1]:
        shot = screenshot(f"PAUSADO-{label}")
        raise AutomationError(f"'{label}' esta cubierto por otra ventana. Captura: {shot}")
    ctypes.windll.user32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.08)
    ctypes.windll.user32.mouse_event(0x0004, 0, 0, 0, 0)
    logging.info("clic %s en %s", label, point)


def add_clips(handle, pid: int, clips: list[Path]) -> None:
    rect = win32gui.GetWindowRect(handle)
    point = (rect[0] + ADD_CLIPS_FROM_TOP_LEFT[0], rect[1] + ADD_CLIPS_FROM_TOP_LEFT[1])
    click(handle, point, "Add clips")
    try:
        dialog = wait_until(lambda: file_dialog(pid), 12, "el selector de archivos de '+ Add clips...'")
    except AutomationError as exc:
        shot = screenshot("PAUSADO-add-clips")
        raise AutomationError(f"{exc}. El boton no estaba donde se esperaba. Captura: {shot}") from exc
    edits = dialog.descendants(class_name="Edit")
    if not edits:
        raise AutomationError("El selector de archivos no tiene campo de nombre.")
    # Primero la carpeta, luego los nombres: evita el limite de longitud con rutas completas.
    folder = clips[0].parent
    edits[0].set_edit_text(str(folder))
    accept_dialog(dialog)
    time.sleep(1.5)
    dialog = wait_until(lambda: file_dialog(pid), 8, "el selector tras entrar a la carpeta")
    names = " ".join(f'"{clip.name}"' for clip in clips)
    dialog.descendants(class_name="Edit")[0].set_edit_text(names)
    accept_dialog(dialog)
    wait_until(lambda: file_dialog(pid) is None, 15, "que el selector se cierre al aceptar los clips")


def export_summary() -> tuple[int, int] | None:
    """(hechos, fallidos) segun el registro del programa, cuando ya cerro el lote."""
    log = Path(os.environ.get("APPDATA", "")) / "VR180SilverBullet2.0" / "vr180-gui.log"
    try:
        found = re.findall(r"export run: complete\D+(\d+) done, (\d+) failed", log.read_text(encoding="utf-8", errors="ignore"))
    except OSError:
        return None
    return (int(found[-1][0]), int(found[-1][1])) if found else None


def unfinished(clip: Path) -> bool:
    out = output_for(clip)
    if not out.exists() or out.stat().st_size == 0:
        return True
    # Mientras exporta el programa escribe temporales junto al destino.
    return any("tmp" in sibling.name.casefold() and sibling.name.startswith(clip.stem)
               for sibling in clip.parent.iterdir())


def run(clips: list[Path], exe: Path, keep_open: bool) -> int:
    if workstation_is_locked():
        raise AutomationError("Windows esta bloqueado. Desbloquea la sesion y vuelve a iniciar.")
    if is_running():
        raise AutomationError("VR180 Silver Bullet ya esta abierto. Cierralo para no mezclar tu trabajo con el lote.")

    check_free_space(clips)
    status(f"Abriendo VR180 Silver Bullet para {len(clips)} clip(s)...")
    process = subprocess.Popen([str(exe)], cwd=str(exe.parent))
    handle = wait_until(lambda: main_window(process.pid), 60, "la ventana de VR180 Silver Bullet")
    time.sleep(4)
    place_window(handle)

    by_folder: dict[Path, list[Path]] = {}
    for clip in clips:
        by_folder.setdefault(clip.parent, []).append(clip)
    for folder, group in by_folder.items():
        status(f"Agregando {len(group)} clip(s) de {folder}")
        add_clips(handle, process.pid, group)
        time.sleep(3 + 0.5 * len(group))

    rect = win32gui.GetWindowRect(handle)
    point = (rect[2] - EXPORT_ALL_FROM_BOTTOM_RIGHT[0], rect[3] - EXPORT_ALL_FROM_BOTTOM_RIGHT[1])
    screenshot("antes-de-exportar")
    click(handle, point, "Export all")
    status("Export all pulsado: esperando que empiece la exportacion...")

    def started():
        return any(output_for(c).exists() or any(s.name.startswith(c.stem) and "tmp" in s.name.casefold()
                                                 for s in c.parent.iterdir()) for c in clips)
    try:
        wait_until(started, 90, "que aparezca el primer archivo de salida", interval=2)
    except AutomationError as exc:
        shot = screenshot("PAUSADO-export-all")
        raise AutomationError(f"{exc}. El programa sigue abierto para que lo revises. Captura: {shot}") from exc
    status("Exportacion iniciada. Ya puedes usar el raton; el programa trabaja solo.")

    begun = time.monotonic()
    last = -1
    while True:
        if process.poll() is not None:
            raise AutomationError("VR180 Silver Bullet se cerro antes de terminar el lote.")
        done = [c for c in clips if not unfinished(c)]
        if len(done) != last:
            last = len(done)
            minutes, seconds = divmod(int(time.monotonic() - begun), 60)
            status(f"Exportando: {len(done)}/{len(clips)} terminados. Tiempo: {minutes:02d}:{seconds:02d}.")
        if len(done) == len(clips):
            break
        summary = export_summary()
        if summary and summary[1]:
            missing = ", ".join(c.name for c in clips if unfinished(c))
            raise AutomationError(f"El programa informo {summary[1]} clip(s) fallidos. Sin exportar: {missing}")
        time.sleep(5)
    time.sleep(10)   # dar tiempo a que cierre el ultimo archivo

    bad = []
    for clip in clips:
        info = probe(output_for(clip))
        if info and any(info.get(key) != value for key, value in EXPECTED.items()):
            bad.append(f"{output_for(clip).name}: {info}")
    if not keep_open and process.poll() is None:
        process.terminate()
    if bad:
        raise AutomationError("Salidas con formato distinto al esperado (HEVC 8192x4096): " + "; ".join(bad))
    status(f"Completado: {len(clips)} clip(s) exportados junto a sus originales.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=APP_NAME)
    parser.add_argument("--source", type=Path, action="append", default=[],
                        help="Carpeta CAM_001 o carpeta de proyecto; repetible")
    parser.add_argument("--root", type=Path, help="Raiz con proyectos 'NNN - Titulo'; toma el CAM_001 de cada uno")
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--limit", type=int, default=0, help="Procesar como maximo N clips (para pruebas)")
    parser.add_argument("--shortest-first", action="store_true", help="Empezar por los archivos mas pequenos")
    parser.add_argument("--analyze", action="store_true", help="Solo listar lo pendiente")
    parser.add_argument("--run", action="store_true", help="Abrir el programa y exportar")
    parser.add_argument("--keep-open", action="store_true", help="No cerrar el programa al terminar")
    args = parser.parse_args()
    if not args.source and not args.root:
        parser.error("Indica --source o --root")
    try:
        clips = discover(args.source, args.root)
        if args.shortest_first:
            clips.sort(key=lambda c: c.stat().st_size)
        if args.limit:
            clips = clips[:args.limit]
        if args.analyze or not args.run:
            total = sum(c.stat().st_size for c in clips) / 2 ** 30
            free = {d: round(shutil.disk_usage(d).free / 2 ** 30) for d in {c.anchor for c in clips}}
            print(json.dumps({"pendientes": len(clips), "gb_originales": round(total, 1),
                              "gb_necesarios_aprox": round(total * OUTPUT_SIZE_RATIO), "gb_libres": free,
                              "clips": [str(c) for c in clips]}, ensure_ascii=False, indent=2))
            return 0
        if not clips:
            status("No hay clips OSV pendientes de exportar.")
            return 0
        return run(clips, find_exe(args.exe), args.keep_open)
    except AutomationError as exc:
        logging.error("%s", exc)
        status(f"DETENIDO: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

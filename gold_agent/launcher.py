"""Interactive Windows startup used by Start_Gold_Agent.cmd."""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HOME = Path(__file__).resolve().parent
GOLD_SYMBOL = "XAUUSD_i"
MT5_PATH = Path(r"C:\Program Files\Weltrade MT5 Demo\terminal64.exe")


def validate_settings(settings):
    if not isinstance(settings, dict) or set(settings) != {"usd_symbol", "usd_inverse", "model"}:
        raise ValueError("Invalid startup settings; remove data/startup.json to configure again")
    if not isinstance(settings["usd_symbol"], str) or not settings["usd_symbol"].strip():
        raise ValueError("USD symbol must be nonempty text")
    if settings["usd_symbol"] == GOLD_SYMBOL:
        raise ValueError("USD comparison cannot be the gold symbol")
    if type(settings["usd_inverse"]) is not bool:
        raise ValueError("USD orientation must be true or false")
    if not isinstance(settings["model"], str) or not settings["model"].strip():
        raise ValueError("Ollama model must be nonempty text")
    if settings["model"].startswith("-") or "cloud" in settings["model"].lower():
        raise ValueError("Use a local Ollama model, not a cloud-backed model")
    return settings


def configure(mt5, path):
    if path.exists():
        return validate_settings(json.loads(path.read_text(encoding="utf-8")))
    symbols = mt5.symbols_get()
    if symbols is None:
        raise RuntimeError(f"Cannot list broker symbols: {mt5.last_error()}")
    names = {symbol.name for symbol in symbols}
    candidates = sorted(name for name in names if any(
        word in name.upper() for word in ("EURUSD", "DXY", "USDX", "USDIDX")
    ))
    print("\nGold symbol: " + GOLD_SYMBOL)
    print("Possible USD comparison symbols: " + (", ".join(candidates) or "none detected"))
    print("Prefer your broker's USD index. EURUSD is only a USD-versus-EUR proxy.")
    while True:
        symbol = input("Enter the exact USD index or FX comparison symbol: ").strip()
        if symbol in names and symbol != GOLD_SYMBOL:
            break
        print("That symbol is not available, or equals gold. Use an exact broker symbol.")
    print("\nSelect the orientation of that symbol:")
    print("1 = Higher price means stronger USD (e.g. DXY or USDJPY)")
    print("2 = Lower price means stronger USD (e.g. EURUSD or GBPUSD)")
    while True:
        orientation = input("Enter 1 or 2: ").strip()
        if orientation in ("1", "2"):
            break
        print("Please enter 1 or 2.")
    model = input("\nLocal Ollama model [qwen2.5:7b]: ").strip() or "qwen2.5:7b"
    return validate_settings({"usd_symbol": symbol, "usd_inverse": orientation == "2", "model": model})


def ollama_models():
    with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=2) as response:
        data = json.loads(response.read(1_000_001))
    if not isinstance(data, dict) or not isinstance(data.get("models"), list):
        raise ValueError("Ollama returned an invalid model list")
    names = []
    for item in data["models"]:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            raise ValueError("Ollama returned an invalid model entry")
        # Cloud-backed entries must never be used for this local-only launcher.
        if not item.get("remote_host") and not item.get("remote_model"):
            names.append(item["name"])
    return names


def model_available(model, names):
    return model in names or (":" not in model and model + ":latest" in names)


def ollama_executable():
    executable = shutil.which("ollama")
    if executable:
        return executable
    candidate = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "Ollama" / "ollama.exe"
    return str(candidate) if candidate.is_file() else None


def start_ollama(executable, log, owned):
    try:
        return ollama_models()
    except OSError:
        if not executable:
            raise RuntimeError(
                "Ollama is not running or installed. Install it from https://ollama.com/download/windows, "
                "then double-click Start_Gold_Agent.cmd again."
            )
    print("Starting local Ollama; startup errors are recorded in data/ollama-startup.log...")
    owned.append(subprocess.Popen(
        [executable, "serve"], stdout=log, stderr=subprocess.STDOUT,
        creationflags=subprocess.CREATE_NO_WINDOW,
        env={**os.environ, "OLLAMA_HOST": "127.0.0.1:11434"},
    ))
    deadline = time.monotonic() + 45
    last_error = None
    while time.monotonic() < deadline:
        try:
            return ollama_models()
        except OSError as exc:
            last_error = exc
            if owned[0].poll() is not None:
                raise RuntimeError("Ollama exited during startup; see data/ollama-startup.log") from exc
            time.sleep(1)
    raise RuntimeError(f"Ollama did not become responsive: {last_error}")


def run():
    if sys.platform != "win32":
        raise RuntimeError("This launcher requires Windows with MetaTrader 5 installed")
    import msvcrt
    import MetaTrader5 as mt5

    output = HOME / "data"
    output.mkdir(exist_ok=True)
    # Windows releases this byte-range lock even if the launcher crashes.
    with (output / "launcher.lock").open("a+b") as lock:
        lock.seek(0, 2)
        if lock.tell() == 0:
            lock.write(b"0")
            lock.flush()
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            raise RuntimeError("Another launcher is already running; use its window") from exc
        if not MT5_PATH.is_file():
            raise RuntimeError(f"MT5 executable not found: {MT5_PATH}. Check MT5_PATH in launcher.py.")
        print(f"Connecting to {MT5_PATH}. Keep this broker terminal logged in.")
        if not mt5.initialize(str(MT5_PATH)):
            raise RuntimeError(f"Cannot connect to MT5: {mt5.last_error()}")
        try:
            if not mt5.symbol_select(GOLD_SYMBOL, True):
                raise RuntimeError(f"Broker gold symbol {GOLD_SYMBOL} unavailable: {mt5.last_error()}")
            path = output / "startup.json"
            settings = configure(mt5, path)
            if not mt5.symbol_select(settings["usd_symbol"], True):
                raise RuntimeError(f"USD comparison symbol unavailable: {mt5.last_error()}")
        finally:
            mt5.shutdown()
        # Persist first-run choices before external setup, so retries don't repeat prompts.
        temporary = output / "startup.json.tmp"
        temporary.write_text(json.dumps(settings, indent=2), encoding="utf-8")
        temporary.replace(path)
        executable = ollama_executable()
        owned = []
        with (output / "ollama-startup.log").open("a", encoding="utf-8") as log:
            try:
                names = start_ollama(executable, log, owned)
                if not model_available(settings["model"], names):
                    if not executable:
                        raise RuntimeError("Model missing; install the Ollama CLI to download it")
                    print(f"\nModel {settings['model']} is not installed locally.")
                    print("Downloading may use several GB of data and disk space.")
                    if input("Download this model now? [y/N]: ").strip().lower() != "y":
                        raise RuntimeError("Model download declined; no monitor was started")
                    subprocess.run(
                        [executable, "pull", settings["model"]], check=True,
                        env={**os.environ, "OLLAMA_HOST": "127.0.0.1:11434"},
                    )
                    if not model_available(settings["model"], ollama_models()):
                        raise RuntimeError("The requested local model is still unavailable")
                print(f"\nStarting {GOLD_SYMBOL} / {settings['usd_symbol']} with {settings['model']}.")
                print("Scans run continuously. Reports: " + str(output / "latest.json"))
                print("Keep this window open. Press Ctrl+C to stop. Your EA is unaffected.")
                command = [
                    sys.executable, str(HOME / "agent.py"), "--gold-symbol", GOLD_SYMBOL,
                    "--usd-symbol", settings["usd_symbol"], "--ollama-model", settings["model"],
                    "--output", str(output),
                    "--mt5-path", str(MT5_PATH),
                ]
                if settings["usd_inverse"]:
                    command.append("--usd-inverse")
                monitor = subprocess.Popen(command)
                try:
                    return monitor.wait()
                except KeyboardInterrupt:
                    # Ctrl+C reaches both consoles; give the agent time to finish cleanup.
                    try:
                        monitor.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        monitor.terminate()
                        monitor.wait()
                    raise
            finally:
                for process in owned:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()


def main():
    try:
        return run()
    except KeyboardInterrupt:
        print("\nMonitor stopped.")
        return 0
    except (OSError, ValueError, RuntimeError, ImportError, subprocess.CalledProcessError) as exc:
        print(f"\nERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Build, sign, and update Margin on paired iOS devices without deleting app data."""
import argparse
import contextlib
import json
import pathlib
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_DEVICES = ["00008150-0008248A3638C01C", "00008103-000D18503AB8A01E"]


def run(*args, **kwargs):
    return subprocess.run(["rtk", "proxy", *map(str, args)], check=True, **kwargs)


@contextlib.contextmanager
def signing_proxy(service, host, port):
    """Xcode uses macOS proxy settings, rather than HTTP_PROXY variables."""
    saved = []
    try:
        for kind in ("web", "secureweb"):
            result = run("networksetup", f"-get{kind}proxy", service,
                         capture_output=True, text=True)
            values = dict(line.split(": ", 1) for line in result.stdout.splitlines() if ": " in line)
            if values.get("Authenticated Proxy Enabled") != "0":
                raise RuntimeError("Authenticated system proxy detected; refusing to overwrite its credentials.")
            saved.append((kind, values))
            run("networksetup", f"-set{kind}proxy", service, host, port)
            run("networksetup", f"-set{kind}proxystate", service, "on")
        yield
    finally:
        for kind, values in reversed(saved):
            # Attempt every restoration even if one networksetup command fails.
            for args in ((f"-set{kind}proxy", service, values["Server"] or "127.0.0.1", values["Port"]),
                         (f"-set{kind}proxystate", service, "on" if values["Enabled"] == "Yes" else "off")):
                try:
                    run("networksetup", *args)
                except subprocess.CalledProcessError:
                    print(f"WARNING: Could not restore {kind} proxy: {args}", file=sys.stderr)


def devices():
    with tempfile.TemporaryDirectory(prefix="margin-devices-") as folder:
        path = pathlib.Path(folder) / "devices.json"
        run("xcrun", "devicectl", "list", "devices", "--json-output", path,
            stdout=subprocess.DEVNULL)
        return json.loads(path.read_text())["result"]["devices"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", action="append", help="Device UDID; repeat for multiple devices")
    parser.add_argument("--proxy-host", default="127.0.0.1")
    parser.add_argument("--proxy-port", type=int, default=10814)
    parser.add_argument("--network-service", default="Wi-Fi")
    parser.add_argument("--team", default="UQVK8AX84B")
    parser.add_argument("--wait", type=int, default=120,
                        help="Seconds to retry disconnected or locked devices (default: 120)")
    options = parser.parse_args()
    if options.wait < 0 or not 1 <= options.proxy_port <= 65535:
        parser.error("--wait must be nonnegative and --proxy-port must be 1–65535")
    proxy = f"http://{options.proxy_host}:{options.proxy_port}"
    run("curl", "--silent", "--show-error", "--fail", "--max-time", "20",
        "--proxy", proxy, "https://developerservices2.apple.com", stdout=subprocess.DEVNULL)
    pending = set(options.device or DEFAULT_DEVICES)
    signed = set()
    deadline = time.monotonic() + options.wait
    app = ROOT / "app/build/device-update/Build/Products/Release-iphoneos/Margin.app"
    while pending:
        for device in devices():
            udid = device.get("hardwareProperties", {}).get("udid")
            if udid not in pending or device.get("connectionProperties", {}).get("tunnelState") == "unavailable":
                continue
            name = device.get("deviceProperties", {}).get("name", udid)
            try:
                if udid not in signed:
                    print(f"Building and signing for {name}…", flush=True)
                    with signing_proxy(options.network_service, options.proxy_host, options.proxy_port):
                        run("xcodebuild", "-quiet", "-project", ROOT / "app/Margin.xcodeproj",
                            "-scheme", "Margin", "-configuration", "Release",
                            "-destination", f"platform=iOS,id={udid}", "-destination-timeout", "15",
                            "-derivedDataPath", ROOT / "app/build/device-update",
                            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
                            f"DEVELOPMENT_TEAM={options.team}", "build")
                    signed.clear()  # The next build may replace the embedded provisioning profile.
                    signed.add(udid)
                run("xcrun", "devicectl", "device", "install", "app", "--device", udid,
                    "--timeout", "45", app)
                print(f"Installed Margin on {name}.", flush=True)
                pending.remove(udid)
            except subprocess.CalledProcessError:
                print(f"Update failed on {name}; keep it connected, unlocked, and trusted.", flush=True)
        if not pending or time.monotonic() >= deadline:
            break
        print("Waiting for devices. Connect and unlock them; Ctrl-C stops retries.", flush=True)
        time.sleep(min(10, max(0, deadline - time.monotonic())))
    if pending:
        print("Not installed on: " + ", ".join(sorted(pending)), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Update stopped: {error}", file=sys.stderr)
        sys.exit(1)

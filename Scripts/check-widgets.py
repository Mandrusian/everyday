#!/usr/bin/env python3
"""Check the packaged widget's entry point; compilation alone misses bootstrap failures."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def run(*args):
    return subprocess.check_output(args, text=True)


def require(condition, message):
    if not condition:
        sys.exit(f"Widget check failed: {message}")


app = Path(sys.argv[1] if len(sys.argv) > 1 else "build/everyday.app")
extension = app / "Contents/PlugIns/EverydayWidgets.appex"
app_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
info = plistlib.loads((extension / "Contents/Info.plist").read_bytes())
binary = extension / "Contents/MacOS" / info["CFBundleExecutable"]
require(info["CFBundleIdentifier"].startswith(app_info["CFBundleIdentifier"] + "."),
        "widget bundle identifier must be under the app identifier")
require(info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
        "missing WidgetKit extension point")
for key in ("CFBundleVersion", "CFBundleShortVersionString"):
    require(info[key] == app_info[key], f"app and widget {key} differ")

for arch in run("lipo", "-archs", str(binary)).split():
    commands = run("otool", "-arch", arch, "-l", str(binary))
    text = re.search(r"segname __TEXT\s+vmaddr (0x[0-9a-fA-F]+)\s+vmsize \S+\s+fileoff (\d+)", commands)
    entry = re.search(r"cmd LC_MAIN\s+cmdsize \d+\s+entryoff (\d+)", commands)
    require(text and entry, f"{arch}: missing text segment or executable entry")
    address = int(text[1], 16) + int(entry[1]) - int(text[2])
    imports = run("otool", "-arch", arch, "-Iv", str(binary))
    require(any(int(match[1], 16) == address for match in
                re.finditer(r"^(0x[0-9a-fA-F]+)\s+\d+\s+_NSExtensionMain$", imports, re.M)),
            f"{arch}: LC_MAIN must enter NSExtensionMain, not Swift main")
    require("sectname __swift5_entry" in commands, f"{arch}: missing Swift entry metadata")
    symbols = run("nm", "-arch", arch, "-g", str(binary))
    require(re.search(r"\bT _main$", symbols, re.M), f"{arch}: Swift main was stripped")

subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print("Widget packaging checks passed (Apple bootstrap, Swift entry, versions, signatures).")

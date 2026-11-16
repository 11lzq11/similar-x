#!/usr/bin/env python3
"""Download the pinned prebuilt libtdjson for one platform.

The native TDLib library is NOT committed to this repo (it is ~13-22 MB
per platform compressed, ~26-59 MB unpacked). CI and developers fetch it
at build time from the pinned release in scripts/tdjson-manifest.json
(Mithka's iebb/mithka-tdjson releases, TDLib 1.8.69). Every download is
SHA-256 verified, and the extracted library is verified too.

Usage (run from the app root):
  python3 scripts/fetch_tdlib.py --platform android
  python3 scripts/fetch_tdlib.py --platform android --arch arm64-v8a
  python3 scripts/fetch_tdlib.py --platform ios
  python3 scripts/fetch_tdlib.py --platform macos
  python3 scripts/fetch_tdlib.py --platform windows [--arch x64|arm64]
  python3 scripts/fetch_tdlib.py --platform linux [--arch x64|arm64]

Targets (relative to the app root):
  android  -> android/app/src/main/jniLibs/<abi>/libtdjson.so
  ios      -> ios/tdjson/tdjson.xcframework (whole archive)
  macos    -> macos/tdjson/libtdjson.dylib
  windows  -> windows/tdjson.dll
  linux    -> linux/libtdjson.so
Already-correct targets are skipped, so re-running is cheap.
"""
import argparse
import hashlib
import io
import json
import os
import sys
import urllib.request
import zipfile

APP_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(APP_ROOT, "scripts", "tdjson-manifest.json")

PLATFORM_ASSETS = {
    "android": ["android-arm64-v8a", "android-armeabi-v7a", "android-x86_64"],
    "ios": ["ios"],
    "macos": ["macos"],
    "windows": ["windows-x64"],
    "linux": ["linux-x64"],
}
ARCH_ASSETS = {
    ("android", "arm64-v8a"): ["android-arm64-v8a"],
    ("android", "armeabi-v7a"): ["android-armeabi-v7a"],
    ("android", "x86_64"): ["android-x86_64"],
    ("windows", "arm64"): ["windows-arm64"],
    ("windows", "x64"): ["windows-x64"],
    ("linux", "arm64"): ["linux-arm64"],
    ("linux", "x64"): ["linux-x64"],
}


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "Similar-X/1.0"})
    with urllib.request.urlopen(req, timeout=300) as resp:
        return resp.read()


def fetch_asset(manifest: dict, key: str) -> None:
    asset = manifest["assets"][key]
    target = os.path.join(APP_ROOT, asset["target"])
    member = asset["member"]
    member_sha = asset["member_sha256"]

    # Skip when the extracted target already matches the manifest.
    if key == "ios":
        sentinel = os.path.join(target, "Info.plist")
        if os.path.exists(sentinel) and sha256_file(sentinel) == member_sha:
            print(f"{key}: already present, skipping")
            return
    elif os.path.exists(target) and sha256_file(target) == member_sha:
        print(f"{key}: already present, skipping")
        return

    tag = manifest["release_tag"]
    repo = manifest["source_repository"]
    url = (
        f"https://github.com/{repo}/releases/download/{tag}/{asset['file']}"
    )
    print(f"{key}: downloading {asset['file']} ...")
    data = download(url)
    if sha256_hex(data) != asset["sha256"]:
        raise RuntimeError(f"{key}: archive SHA-256 mismatch, refusing to use it")
    zf = zipfile.ZipFile(io.BytesIO(data))
    if key == "ios":
        # Extract the whole XCFramework directory.
        dest_dir = os.path.dirname(target)
        os.makedirs(dest_dir, exist_ok=True)
        zf.extractall(dest_dir)
    else:
        raw = zf.read(member)
        if sha256_hex(raw) != member_sha:
            raise RuntimeError(f"{key}: library SHA-256 mismatch, refusing to use it")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as f:
            f.write(raw)
    print(f"{key}: installed -> {asset['target']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True,
                        choices=sorted(PLATFORM_ASSETS))
    parser.add_argument("--arch", default=None,
                        help="e.g. arm64-v8a, x86_64, x64, arm64")
    args = parser.parse_args()

    with open(MANIFEST, encoding="utf-8") as f:
        manifest = json.load(f)

    keys = ARCH_ASSETS.get((args.platform, args.arch))
    if keys is None:
        if args.arch is not None:
            parser.error(f"unknown --arch {args.arch!r} for {args.platform}")
        keys = PLATFORM_ASSETS[args.platform]

    for key in keys:
        fetch_asset(manifest, key)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

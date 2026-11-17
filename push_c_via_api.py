#!/usr/bin/env python3
"""Push ~/workspace/tiny-ai-trainer-c to 11lzq11/similar-x via the Git Data API,
REPLACING all existing content (the repo previously held Similar-X).

Steps:
  1. Fetch current similar-x main ref + tree (recursive) -> old file list.
  2. Create blobs for all C files (only ones whose index SHA changed).
  3. Create a new tree on the current main tree: C blobs overwrite
     same-path files; old-only paths are deleted (sha null).
  4. Create a commit with current main as parent; PATCH main to it.
Progress saved to push_state_c.json. Re-runnable.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import add_surrogate_to_request, read_json_response

APP_DIR = os.path.expanduser("~/workspace/tiny-ai-trainer-c")
REPO = "11lzq11/similar-x"
COMMIT_MSG = "feat: TinyTrainer C - Flutter cross-platform trainer (replaces Similar-X)"
STATE_FILE = os.path.expanduser("~/workspace/tiny-ai-trainer-c/push_state_c.json")


def commit_message() -> str:
    if len(sys.argv) > 1:
        return sys.argv[1]
    return COMMIT_MSG


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise RuntimeError("redirect refused, verify the endpoint")


def gh(method, path, data=None, retries=3):
    for attempt in range(1, retries + 1):
        body = None
        if data is not None:
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(
            "https://api.github.com" + path, data=body, method=method
        )
        request.add_header("Accept", "application/vnd.github+json")
        request.add_header("X-GitHub-Api-Version", "2022-11-28")
        if body is not None:
            request.add_header("Content-Type", "application/json")
        add_surrogate_to_request(
            request, "custom.github", allowed_hosts=["api.github.com"]
        )
        try:
            with urllib.request.build_opener(NoRedirect()).open(
                request, timeout=120
            ) as response:
                return read_json_response(response)
        except urllib.error.HTTPError as e:
            err = e.read().decode("utf-8", errors="replace")
            print(f"  [{method} {path}] attempt {attempt} failed: "
                  f"HTTP {e.code} {err[:300]}", file=sys.stderr)
            if attempt < retries:
                time.sleep(2 * attempt)
        except Exception as e:
            print(f"  [{method} {path}] attempt {attempt} failed: {e}",
                  file=sys.stderr)
            if attempt < retries:
                time.sleep(2 * attempt)
    raise RuntimeError(f"{method} {path} failed after {retries} attempts")


def is_binary(data: bytes) -> bool:
    try:
        data.decode("utf-8")
        return False
    except UnicodeDecodeError:
        return True


def main():
    state = {}
    if os.path.exists(STATE_FILE):
        state = json.load(open(STATE_FILE))
    blobs = state.get("blobs", {})

    out = subprocess.run(
        ["git", "-C", APP_DIR, "ls-files", "-s"],
        capture_output=True, text=True, check=True,
    ).stdout
    files = []  # (mode, index_sha, path)
    for line in out.strip().split("\n"):
        meta, path = line.split("\t", 1)
        mode, index_sha = meta.split()[0], meta.split()[1]
        files.append((mode, index_sha, path))
    print(f"{len(files)} files to push")

    # Current similar-x main + its full file list (for deletions).
    ref = gh("GET", f"/repos/{REPO}/git/refs/heads/main")
    parent_sha = ref["object"]["sha"]
    commit = gh("GET", f"/repos/{REPO}/git/commits/{parent_sha}")
    base_tree = commit["tree"]["sha"]
    print(f"similar-x main at {parent_sha}")
    tree_resp = gh("GET",
                   f"/repos/{REPO}/git/trees/{parent_sha}?recursive=1")
    old_files = [t["path"] for t in tree_resp.get("tree", [])
                 if t["type"] == "blob"]
    print(f"old similar-x files: {len(old_files)}")
    new_paths = {path for _, _, path in files}
    deletions = [p for p in old_files if p not in new_paths]
    print(f"paths to delete: {len(deletions)} "
          f"(overwritten by C: {len(old_files) - len(deletions)})")

    # Blobs (only changed files).
    for i, (mode, index_sha, path) in enumerate(files, 1):
        if blobs.get(path) == index_sha:
            continue
        full = os.path.join(APP_DIR, path)
        data = open(full, "rb").read()
        if is_binary(data):
            payload = {"content": base64.b64encode(data).decode(),
                       "encoding": "base64"}
        else:
            payload = {"content": data.decode("utf-8"), "encoding": "utf-8"}
        resp = gh("POST", f"/repos/{REPO}/git/blobs", payload)
        blobs[path] = resp["sha"]
        if i % 20 == 0 or i == len(files):
            print(f"  blobs: {i}/{len(files)}")
            state["blobs"] = blobs
            json.dump(state, open(STATE_FILE, "w"))
    state["blobs"] = blobs
    json.dump(state, open(STATE_FILE, "w"))
    print(f"blobs done: {len(blobs)}")

    # Tree: C blobs + deletions of old-only paths.
    tree_entries = [
        {"path": path, "mode": mode, "type": "blob", "sha": blobs[path]}
        for mode, index_sha, path in files
    ]
    for path in deletions:
        tree_entries.append(
            {"path": path, "mode": "100644", "type": "blob", "sha": None}
        )
    resp = gh("POST", f"/repos/{REPO}/git/trees",
              {"base_tree": base_tree, "tree": tree_entries})
    tree_sha = resp["sha"]
    print(f"tree: {tree_sha}")

    resp = gh("POST", f"/repos/{REPO}/git/commits",
              {"message": commit_message(), "tree": tree_sha,
               "parents": [parent_sha]})
    commit_sha = resp["sha"]
    print(f"commit: {commit_sha}")

    resp = gh("PATCH", f"/repos/{REPO}/git/refs/heads/main",
              {"sha": commit_sha})
    print(f"ref updated: {resp['ref']} -> {resp['object']['sha']}")

    state.update({"tree": tree_sha, "commit": commit_sha,
                  "parent_sha": commit_sha, "base_tree": tree_sha})
    json.dump(state, open(STATE_FILE, "w"))
    print(f"COMMIT_SHA={commit_sha}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Add the TDLib native library to the iOS and macOS Xcode projects.

Run once (idempotent — re-running is a no-op). Edits the .pbxproj files
directly; there is no macOS/Xcode here to validate with, so the script
verifies its own edits by re-reading the file and checking every
reference it added is present and unique.

iOS: links + embeds ios/tdjson/tdjson.xcframework (fetched by
scripts/fetch_tdlib.py --platform ios) and adds $(PROJECT_DIR)/tdjson
to FRAMEWORK_SEARCH_PATHS so the linker finds it.
macOS: links macos/tdjson/libtdjson.dylib and copies it into the app
bundle's Frameworks directory (the "Bundle Framework" phase), and adds
$(PROJECT_DIR)/tdjson to LIBRARY_SEARCH_PATHS.
"""
import re
import secrets
import sys

IOS_PBX = "ios/Runner.xcodeproj/project.pbxproj"
MAC_PBX = "macos/Runner.xcodeproj/project.pbxproj"


def new_id(existing: set) -> str:
    while True:
        ident = secrets.token_hex(12).upper()
        if ident not in existing:
            existing.add(ident)
            return ident


def load(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def save(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def existing_ids(text: str) -> set:
    return set(re.findall(r"\b[0-9A-F]{24}\b", text))


def insert_after_once(text: str, anchor: str, insertion: str, what: str) -> str:
    if insertion.strip() in text:
        return text  # already present
    idx = text.find(anchor)
    if idx < 0:
        raise RuntimeError(f"anchor not found for {what}: {anchor[:60]!r}")
    return text[: idx + len(anchor)] + insertion + text[idx + len(anchor) :]


def add_to_phase_files(
    text: str, phase_id: str, phase_comment: str, entry: str, what: str
) -> str:
    # Find "<id> /* <comment> */ = {\n ... files = (\n ... );" and insert.
    # group(2) captures the existing file lines INCLUDING the trailing
    # newline, so the new entry lands on its own line.
    pat = re.compile(
        r"(" + re.escape(phase_id) + r" /\* " + re.escape(phase_comment) +
        r" \*/ = \{\n(?:.*?\n)*?\t\t\tfiles = \(\n)(.*?)(\t\t\t\);)",
        re.DOTALL,
    )
    m = pat.search(text)
    if not m:
        raise RuntimeError(f"phase not found: {phase_id} {phase_comment}")
    if entry.strip() in m.group(2):
        return text
    new_files = m.group(2) + entry
    return text[: m.start()] + m.group(1) + new_files + m.group(3) + text[m.end():]


def add_to_group_children(
    text: str, group_id: str, group_comment: str, entry: str
) -> str:
    pat = re.compile(
        r"(" + re.escape(group_id) + r" /\* " + re.escape(group_comment) +
        r" \*/ = \{\n(?:.*?\n)*?\t\t\tchildren = \(\n)(.*?)(\t\t\t\);)",
        re.DOTALL,
    )
    m = pat.search(text)
    if not m:
        raise RuntimeError(f"group not found: {group_id} {group_comment}")
    if entry.strip() in m.group(2):
        return text
    return (
        text[: m.start()] + m.group(1) + m.group(2) + entry +
        m.group(3) + text[m.end():]
    )


def runner_config_ids(text: str, config_list_id: str) -> list:
    """IDs of the XCBuildConfigurations in the Runner target's list."""
    pat = re.compile(
        re.escape(config_list_id) + r" /\* [^*]* \*/ = \{\n"
        r"\t\t\tisa = XCConfigurationList;\n"
        r"\t\t\tbuildConfigurations = \(\n(.*?)\n\t\t\t\);",
        re.DOTALL,
    )
    m = pat.search(text)
    if not m:
        raise RuntimeError(f"config list not found: {config_list_id}")
    return re.findall(r"([0-9A-F]{24}) /\*", m.group(1))


def add_search_path(
    text: str, config_id: str, setting: str, value: str
) -> str:
    """Add `setting = ("$(inherited)", "<value>");` to one config's
    buildSettings, right after ALWAYS_SEARCH_USER_PATHS (or at the top
    of buildSettings if that line is absent)."""
    block_pat = re.compile(
        r"(" + re.escape(config_id) + r" /\* (?:Debug|Release|Profile) \*/ = \{\n"
        r"\t\t\tisa = XCBuildConfiguration;\n"
        r"(?:\t\t\tbaseConfigurationReference = [^\n]*\n)?"
        r"\t\t\tbuildSettings = \{\n)(.*?)(\n\t\t\t\};)",
        re.DOTALL,
    )
    m = block_pat.search(text)
    if not m:
        raise RuntimeError(f"config not found: {config_id}")
    body = m.group(2)
    if setting in body:
        return text
    insertion = (
        f'\t\t\t\t{setting} = (\n'
        f'\t\t\t\t\t"$(inherited)",\n'
        f'\t\t\t\t\t"{value}",\n'
        f'\t\t\t\t);\n'
    )
    anchor = "\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n"
    if anchor in body:
        new_body = body.replace(anchor, anchor + insertion, 1)
    else:
        new_body = insertion + body
    return text[: m.start()] + m.group(1) + new_body + m.group(3) + text[m.end():]


def edit_ios() -> None:
    text = load(IOS_PBX)
    if "tdjson.xcframework" in text:
        print("iOS: already present, skipping")
        return
    ids = existing_ids(text)
    ref = new_id(ids)
    link = new_id(ids)
    embed = new_id(ids)

    # 1. File reference for the XCFramework.
    text = insert_after_once(
        text,
        "/* Begin PBXFileReference section */\n",
        f"\t\t{ref} /* tdjson.xcframework */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = wrapper.xcframework; "
        f"path = tdjson/tdjson.xcframework; sourceTree = \"<group>\"; }};\n",
        "ios file reference",
    )
    # 2. Build files (link + embed).
    text = insert_after_once(
        text,
        "/* Begin PBXBuildFile section */\n",
        f"\t\t{link} /* tdjson.xcframework in Frameworks */ = "
        f"{{isa = PBXBuildFile; fileRef = {ref} /* tdjson.xcframework */; }};\n"
        f"\t\t{embed} /* tdjson.xcframework in Embed Frameworks */ = "
        f"{{isa = PBXBuildFile; fileRef = {ref} /* tdjson.xcframework */; "
        f"settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};\n",
        "ios build files",
    )
    # 3. Runner group children.
    text = add_to_group_children(
        text, "97C146F01CF9000F007C117D", "Runner",
        f"\t\t\t\t{ref} /* tdjson.xcframework */,\n",
    )
    # 4. Link it (Frameworks phase) and embed it (Embed Frameworks).
    text = add_to_phase_files(
        text, "97C146EB1CF9000F007C117D", "Frameworks",
        f"\t\t\t\t{link} /* tdjson.xcframework in Frameworks */,\n",
        "ios link phase",
    )
    text = add_to_phase_files(
        text, "9705A1C41CF9048500538489", "Embed Frameworks",
        f"\t\t\t\t{embed} /* tdjson.xcframework in Embed Frameworks */,\n",
        "ios embed phase",
    )
    # 5. Framework search path on the Runner target's configs.
    for cfg in runner_config_ids(text, "97C147051CF9000F007C117D"):
        text = add_search_path(
            text, cfg, "FRAMEWORK_SEARCH_PATHS", "$(PROJECT_DIR)/tdjson",
        )
    save(IOS_PBX, text)
    print(f"iOS: ref={ref} link={link} embed={embed}")


def edit_macos() -> None:
    text = load(MAC_PBX)
    if "libtdjson.dylib" in text:
        print("macOS: already present, skipping")
        return
    ids = existing_ids(text)
    ref = new_id(ids)
    link = new_id(ids)
    copy = new_id(ids)

    # 1. File reference for the dylib.
    text = insert_after_once(
        text,
        "/* Begin PBXFileReference section */\n",
        f"\t\t{ref} /* libtdjson.dylib */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = \"compiled.mach-o.dylib\"; "
        f"path = tdjson/libtdjson.dylib; sourceTree = \"<group>\"; }};\n",
        "macos file reference",
    )
    # 2. Build files (link + copy into Frameworks).
    text = insert_after_once(
        text,
        "/* Begin PBXBuildFile section */\n",
        f"\t\t{link} /* libtdjson.dylib in Frameworks */ = "
        f"{{isa = PBXBuildFile; fileRef = {ref} /* libtdjson.dylib */; }};\n"
        f"\t\t{copy} /* libtdjson.dylib in Bundle Framework */ = "
        f"{{isa = PBXBuildFile; fileRef = {ref} /* libtdjson.dylib */; "
        f"settings = {{ATTRIBUTES = (CodeSignOnCopy, ); }}; }};\n",
        "macos build files",
    )
    # 3. Runner group children.
    text = add_to_group_children(
        text, "33FAB671232836740065AC1E", "Runner",
        f"\t\t\t\t{ref} /* libtdjson.dylib */,\n",
    )
    # 4. Link it (Frameworks phase) and copy it (Bundle Framework).
    text = add_to_phase_files(
        text, "33CC10EA2044A3C60003C045", "Frameworks",
        f"\t\t\t\t{link} /* libtdjson.dylib in Frameworks */,\n",
        "macos link phase",
    )
    text = add_to_phase_files(
        text, "33CC110E2044A8840003C045", "Bundle Framework",
        f"\t\t\t\t{copy} /* libtdjson.dylib in Bundle Framework */,\n",
        "macos copy phase",
    )
    # 5. Library search path on the Runner target's configs.
    for cfg in runner_config_ids(text, "33CC10FB2044A3C60003C045"):
        text = add_search_path(
            text, cfg, "LIBRARY_SEARCH_PATHS", "$(PROJECT_DIR)/tdjson",
        )
    save(MAC_PBX, text)
    print(f"macOS: ref={ref} link={link} copy={copy}")


def verify(path: str, needles: dict) -> None:
    """needles: text -> expected count. Checks balanced delimiters too."""
    text = load(path)
    if text.count("{") != text.count("}"):
        raise RuntimeError(f"{path}: unbalanced braces")
    if text.count("(") != text.count(")"):
        raise RuntimeError(f"{path}: unbalanced parens")
    for n, want in needles.items():
        c = text.count(n)
        if c != want:
            raise RuntimeError(f"{path}: {n!r} found {c} times (want {want})")
    print(f"verified {path}")


def main() -> int:
    edit_ios()
    edit_macos()
    verify(IOS_PBX, {
        # Each comment appears twice: once in the PBXBuildFile
        # definition, once in the build phase's file list.
        "tdjson.xcframework in Frameworks": 2,
        "tdjson.xcframework in Embed Frameworks": 2,
        # One per Runner target config (Debug, Release, Profile).
        'FRAMEWORK_SEARCH_PATHS = (\n\t\t\t\t\t"$(inherited)",\n'
        '\t\t\t\t\t"$(PROJECT_DIR)/tdjson",': 3,
    })
    verify(MAC_PBX, {
        "libtdjson.dylib in Frameworks": 2,
        "libtdjson.dylib in Bundle Framework": 2,
        'LIBRARY_SEARCH_PATHS = (\n\t\t\t\t\t"$(inherited)",\n'
        '\t\t\t\t\t"$(PROJECT_DIR)/tdjson",': 3,
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

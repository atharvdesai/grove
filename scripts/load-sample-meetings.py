#!/usr/bin/env python3
"""Loads fictional sample meetings into your Grove library, or removes them.

Nine invented meetings for a made-up startup across October 2026 — pricing
decisions that later change, a customer rollout, a hiring loop, a 1:1, a
stand-up, an offsite — so chat, notes timestamps and auto-filing have
something realistic to work on without recording anything.

    ./scripts/load-sample-meetings.py              # add them
    ./scripts/load-sample-meetings.py --remove     # take them out again
    ./scripts/load-sample-meetings.py --dir PATH   # a library somewhere else

The meetings are moved forward in time so the latest one was yesterday, which
keeps "This week" and recent-first ordering meaningful whenever you load them.
Pass --keep-dates to load them in October 2026 as written.

Writes the same three files the app does for each meeting. Removal deletes only
meetings whose id is in samples/sample-meetings.json, never anything else; the
folders it created (Acme, Hiring, Product) are left for you to delete.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

SAMPLES = Path(__file__).resolve().parent.parent / "samples" / "sample-meetings.json"


def library_dir(override):
    if override:
        return Path(override).expanduser()
    # The app's Settings can move the library; honour that if it was changed.
    try:
        custom = subprocess.run(
            ["defaults", "read", "app.grove.Grove", "storagePath"],
            capture_output=True, text=True, check=True).stdout.strip()
        if custom:
            return Path(custom).expanduser()
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return Path.home() / "Documents" / "Grove"


def parse_date(text):
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def format_date(date):
    return date.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def shifted_to_recent(meetings):
    """Moves every meeting by the same whole number of days so the latest one
    lands yesterday, keeping their order, gaps and times of day."""
    latest = max(parse_date(m["startedAt"]) for m in meetings)
    yesterday = datetime.now(timezone.utc) - timedelta(days=1)
    offset = timedelta(days=(yesterday.date() - latest.date()).days)
    for meeting in meetings:
        for key in ("startedAt", "endedAt"):
            if key in meeting:
                meeting[key] = format_date(parse_date(meeting[key]) + offset)
    return meetings


def sanitized(name):
    """MeetingStore.sanitized: one safe path component."""
    return name.replace("/", "-").replace(":", "-").strip().strip(".")


def folder_name(meeting):
    """Meeting.folderName, in local time like the app's DateFormatter, so the
    app finds these at the path it expects when renaming or deleting them."""
    stamp = parse_date(meeting["startedAt"]).astimezone().strftime("%Y-%m-%d-%H%M")
    slug = re.sub(r"[^a-z0-9]+", "-", meeting["title"].lower()).strip("-")
    return f"{stamp}-{slug[:48] if slug else 'meeting'}"


def clock(seconds):
    total = int(seconds)
    return f"{total // 60:02d}:{total % 60:02d}"


def notes_markdown(meeting):
    started = parse_date(meeting["startedAt"]).astimezone()
    lines = [
        "---",
        f"title: {meeting['title']}",
        f"date: {meeting['startedAt']}",
        f"duration_minutes: {int(meeting['recordedDuration'] // 60)}",
        f"template: {meeting['templateID']}",
    ]
    if meeting.get("attendees"):
        lines.append(f"attendees: [{', '.join(meeting['attendees'])}]")
    lines += [
        "---",
        "",
        f"# {meeting['title']}",
        "",
        f"*{started.strftime('%A, %B %-d, %Y at %-I:%M %p')}*",
        "",
    ]
    enhanced = meeting.get("enhancedNotes")
    rough = meeting["roughNotes"]
    if enhanced:
        lines.append(enhanced)
    else:
        lines += ["## Notes", "", rough or "*No notes taken.*"]
    if rough and enhanced:
        lines += ["", "---", "", "## My original notes", "", rough]
    return "\n".join(lines) + "\n"


def transcript_markdown(meeting):
    lines = [f"# Transcript — {meeting['title']}", ""]
    for segment in meeting["transcript"]["segments"]:
        speaker = "Me" if segment["speaker"] == "me" else meeting.get("speakerName") or "Them"
        lines.append(f"**{speaker}** `{clock(segment['start'])}`  \n{segment['text']}\n")
    return "\n".join(lines)


def existing_meetings(base):
    """id -> directory, across the top level and one level of folders."""
    found = {}
    if not base.exists():
        return found
    for entry in base.iterdir():
        for candidate in [entry] + (list(entry.iterdir()) if entry.is_dir() else []):
            manifest = candidate / "meeting.json"
            if candidate.is_dir() and manifest.exists():
                try:
                    found[json.loads(manifest.read_text())["id"].upper()] = candidate
                except (ValueError, KeyError):
                    pass
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--remove", action="store_true", help="remove the sample meetings")
    parser.add_argument("--dir", help="library folder (default: the app's)")
    parser.add_argument("--keep-dates", action="store_true", help="keep the October 2026 dates")
    args = parser.parse_args()

    base = library_dir(args.dir)
    meetings = json.loads(SAMPLES.read_text())["meetings"]
    if not args.keep_dates:
        meetings = shifted_to_recent(meetings)
    present = existing_meetings(base)

    if args.remove:
        removed = 0
        for meeting in meetings:
            directory = present.get(meeting["id"].upper())
            if directory:
                shutil.rmtree(directory)
                removed += 1
        print(f"Removed {removed} sample meeting(s) from {base}")
        return

    added = 0
    for meeting in meetings:
        if meeting["id"].upper() in present:
            continue
        parent = base / sanitized(meeting["folder"]) if meeting.get("folder") else base
        directory = parent / folder_name(meeting)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "meeting.json").write_text(
            json.dumps(meeting, indent=2, sort_keys=True, ensure_ascii=False))
        (directory / "notes.md").write_text(notes_markdown(meeting))
        (directory / "transcript.md").write_text(transcript_markdown(meeting))
        added += 1

    print(f"Added {added} sample meeting(s) to {base}")
    if added < len(meetings):
        print(f"({len(meetings) - added} were already there)")
    print("Quit and reopen Grove, or switch folders in Settings, to see them.")


if __name__ == "__main__":
    sys.exit(main())

"""Turn media files into a bounded set of embeddable segments.

  * image -> one whole-file segment.
  * video -> evenly-spaced still frames (cheap inline JPEGs), capped at
    MAX_VIDEO_FRAMES. This keeps even a feature-length film to a few dozen small
    image embeddings instead of dozens of huge clip uploads.
  * audio -> clips under the API's 180s cap, sampled across the file and capped
    at MAX_AUDIO_SEGMENTS.

ffmpeg (the binary bundled by `imageio-ffmpeg`) does the probing/slicing/frame
grabbing; every invocation has a hard timeout so a bad file can't hang indexing.
If ffmpeg is unavailable we degrade gracefully to a single whole-file segment.
"""
from __future__ import annotations

import logging
import math
import os
import re
import shutil
import subprocess
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Iterator, List, Optional

import config

log = logging.getLogger(__name__)


@dataclass
class MediaSegment:
    """One embeddable slice of a media file, referenced by an on-disk path."""

    index: int
    path: str            # original file, or a temp clip / extracted frame
    mime_type: str
    label: str = ""      # human-readable, e.g. "0:00–2:50" or "frame 12:34"
    start_seconds: Optional[float] = None
    end_seconds: Optional[float] = None


def _ffmpeg_exe() -> Optional[str]:
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:  # noqa: BLE001
        return shutil.which("ffmpeg")


def _run(args: List[str], timeout: Optional[int] = None) -> Optional[subprocess.CompletedProcess]:
    """Run ffmpeg with a hard timeout; None on timeout/failure."""
    try:
        return subprocess.run(
            args, capture_output=True, text=True,
            timeout=timeout or config.FFMPEG_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        log.warning("ffmpeg timed out after %ss: %s", timeout or config.FFMPEG_TIMEOUT_SECONDS, args[-1])
    except Exception as exc:  # noqa: BLE001
        log.warning("ffmpeg invocation failed: %s", exc)
    return None


_DURATION_RE = re.compile(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)")


def _probe_duration(ffmpeg: str, path: str) -> Optional[float]:
    """Seconds of duration parsed from ffmpeg's banner, or None if unknown."""
    proc = _run([ffmpeg, "-i", path, "-hide_banner"], timeout=60)
    if proc is None:
        return None
    match = _DURATION_RE.search(proc.stderr or "")
    if not match:
        return None
    hours, minutes, seconds = match.groups()
    return int(hours) * 3600 + int(minutes) * 60 + float(seconds)


def _fmt(seconds: float) -> str:
    total = int(round(seconds))
    return f"{total // 60}:{total % 60:02d}"


def _label(start: float, end: float) -> str:
    return f"{_fmt(start)}–{_fmt(end)}"


def _ok(proc: Optional[subprocess.CompletedProcess], dst: str) -> bool:
    return (proc is not None and proc.returncode == 0
            and os.path.exists(dst) and os.path.getsize(dst) > 0)


def _slice_audio(ffmpeg: str, src: str, dst: str, start: float, duration: float) -> bool:
    proc = _run([ffmpeg, "-y", "-ss", str(start), "-i", src, "-t", str(duration),
                 "-c", "copy", "-loglevel", "error", dst])
    return _ok(proc, dst)


def _extract_frame(ffmpeg: str, src: str, dst: str, at: float) -> bool:
    proc = _run([ffmpeg, "-y", "-ss", str(at), "-i", src, "-frames:v", "1",
                 "-q:v", "3", "-loglevel", "error", dst])
    return _ok(proc, dst)


def _video_frames(ffmpeg: str, path: str, duration: float, tmpdir: str) -> List[MediaSegment]:
    """Evenly-spaced still frames (midpoints), capped at MAX_VIDEO_FRAMES."""
    interval = max(1, config.VIDEO_FRAME_INTERVAL_SECONDS)
    count = min(config.MAX_VIDEO_FRAMES, max(1, round(duration / interval)))
    segments: List[MediaSegment] = []
    for i in range(count):
        at = (i + 0.5) * duration / count
        dst = os.path.join(tmpdir, f"frame_{i:04d}.jpg")
        if _extract_frame(ffmpeg, path, dst, at):
            segments.append(MediaSegment(
                index=len(segments), path=dst, mime_type="image/jpeg",
                label=f"frame {_fmt(at)}", start_seconds=at, end_seconds=at,
            ))
    return segments


def _audio_clips(ffmpeg: str, path: str, mime: str, duration: float, tmpdir: str) -> List[MediaSegment]:
    """Clips under the audio cap, sampled across the file, bounded by MAX_AUDIO_SEGMENTS."""
    cap = max(1, config.AUDIO_SEGMENT_SECONDS)
    count = min(config.MAX_AUDIO_SEGMENTS, max(1, math.ceil(duration / cap)))
    step = duration / count
    ext = os.path.splitext(path)[1].lower()
    segments: List[MediaSegment] = []
    for i in range(count):
        start = i * step
        dur = min(float(cap), duration - start)
        if dur <= 0:
            break
        dst = os.path.join(tmpdir, f"aud_{i:04d}{ext}")
        if _slice_audio(ffmpeg, path, dst, start, dur):
            segments.append(MediaSegment(
                index=len(segments), path=dst, mime_type=mime,
                label=_label(start, start + dur),
                start_seconds=start, end_seconds=start + dur,
            ))
    return segments


@contextmanager
def segmented(file_path: str, modality: str) -> Iterator[List[MediaSegment]]:
    """Yield the embeddable segments for a media file; temp files cleaned on exit."""
    ext = os.path.splitext(file_path)[1].lower()
    mime = config.MIME_BY_EXT.get(ext, "application/octet-stream")

    if modality == "image":
        yield [MediaSegment(index=0, path=file_path, mime_type=mime)]
        return

    ffmpeg = _ffmpeg_exe()
    duration = _probe_duration(ffmpeg, file_path) if ffmpeg else None

    # Short audio fits in one segment; no need to slice or use temp files.
    if modality == "audio" and duration is not None and duration <= config.AUDIO_SEGMENT_SECONDS:
        yield [MediaSegment(index=0, path=file_path, mime_type=mime)]
        return

    # Can't analyze (no ffmpeg / unreadable duration) — embed the whole file once.
    if not ffmpeg or duration is None or duration <= 0:
        if ffmpeg is None:
            log.warning("ffmpeg unavailable; embedding %s as a single segment", file_path)
        else:
            log.warning("could not probe duration of %s; embedding it as one segment", file_path)
        yield [MediaSegment(index=0, path=file_path, mime_type=mime)]
        return

    tmpdir = tempfile.mkdtemp(prefix="sff_media_")
    try:
        if modality == "video":
            segments = _video_frames(ffmpeg, file_path, duration, tmpdir)
        else:  # audio
            segments = _audio_clips(ffmpeg, file_path, mime, duration, tmpdir)
        yield segments or [MediaSegment(index=0, path=file_path, mime_type=mime)]
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

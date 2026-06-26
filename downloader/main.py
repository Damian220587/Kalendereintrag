import os
import asyncio
import tempfile
import re
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import yt_dlp

app = FastAPI()

class DownloadRequest(BaseModel):
    url: str
    quality: str = "best"

def sanitize_filename(name: str) -> str:
    return re.sub(r'[^\w\s\-.]', '', name).strip()[:100]

@app.get("/", response_class=HTMLResponse)
async def root():
    with open(os.path.join(os.path.dirname(__file__), "static", "index.html"), encoding="utf-8") as f:
        return f.read()

@app.post("/api/info")
async def get_info(req: DownloadRequest):
    def fetch_info():
        ydl_opts = {
            "quiet": True,
            "no_warnings": True,
            "extract_flat": False,
        }
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            return ydl.extract_info(req.url, download=False)

    try:
        info = await asyncio.get_event_loop().run_in_executor(None, fetch_info)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

    formats = []
    for f in info.get("formats", []):
        if f.get("vcodec") != "none" and f.get("ext") in ("mp4", "webm"):
            height = f.get("height")
            if height:
                formats.append({"id": f["format_id"], "label": f"{height}p", "height": height})

    seen = set()
    unique_formats = []
    for f in sorted(formats, key=lambda x: x["height"], reverse=True):
        if f["label"] not in seen:
            seen.add(f["label"])
            unique_formats.append(f)

    return JSONResponse({
        "title": info.get("title", "Video"),
        "thumbnail": info.get("thumbnail"),
        "duration": info.get("duration"),
        "uploader": info.get("uploader") or info.get("channel"),
        "platform": info.get("extractor_key", ""),
        "formats": unique_formats[:5],
    })

@app.post("/api/download")
async def download(req: DownloadRequest):
    tmpdir = tempfile.mkdtemp()
    result = {}

    def do_download():
        if req.quality == "audio":
            fmt = "bestaudio/best"
        elif req.quality == "best":
            fmt = "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"
        else:
            fmt = f"bestvideo[height<={req.quality}][ext=mp4]+bestaudio[ext=m4a]/best[height<={req.quality}][ext=mp4]/best"

        ydl_opts = {
            "outtmpl": os.path.join(tmpdir, "%(title).80s.%(ext)s"),
            "format": fmt,
            "quiet": True,
            "no_warnings": True,
            "merge_output_format": "mp4",
        }
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(req.url)
            result["filepath"] = ydl.prepare_filename(info).replace(".webm", ".mp4").replace(".mkv", ".mp4")
            result["title"] = info.get("title", "video")

    try:
        await asyncio.get_event_loop().run_in_executor(None, do_download)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

    filepath = result["filepath"]
    if not os.path.exists(filepath):
        files = os.listdir(tmpdir)
        if not files:
            raise HTTPException(status_code=500, detail="Download failed")
        filepath = os.path.join(tmpdir, files[0])

    filename = sanitize_filename(result["title"]) + ".mp4"
    filesize = os.path.getsize(filepath)

    def stream():
        with open(filepath, "rb") as f:
            while chunk := f.read(65536):
                yield chunk
        try:
            os.unlink(filepath)
            os.rmdir(tmpdir)
        except Exception:
            pass

    return StreamingResponse(
        stream(),
        media_type="video/mp4",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"',
            "Content-Length": str(filesize),
        },
    )

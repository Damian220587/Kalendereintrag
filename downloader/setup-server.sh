#!/bin/bash
# VOID Video Downloader - Server Setup Script
# Einmalig ausführen auf dem Hetzner Server

set -e

echo "==> Pakete installieren..."
apt-get update -qq
apt-get install -y -qq python3 python3-pip ffmpeg

echo "==> Python-Pakete installieren..."
pip3 install -q yt-dlp fastapi uvicorn python-multipart

echo "==> App-Verzeichnis erstellen..."
mkdir -p /opt/void/static

echo "==> main.py schreiben..."
cat > /opt/void/main.py << 'PYEOF'
import os
import asyncio
import tempfile
import re
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse, HTMLResponse, JSONResponse
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
        ydl_opts = {"quiet": True, "no_warnings": True}
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
PYEOF

echo "==> index.html schreiben..."
cat > /opt/void/static/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>VOID — Video Downloader</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root {
      --bg: #04040d;
      --surface: rgba(255,255,255,0.03);
      --border: rgba(0, 210, 255, 0.15);
      --border-hover: rgba(0, 210, 255, 0.4);
      --accent: #00d2ff;
      --accent-dim: rgba(0, 210, 255, 0.12);
      --accent-glow: rgba(0, 210, 255, 0.25);
      --text: #e8eaf0;
      --text-dim: rgba(232,234,240,0.45);
      --error: #ff4d6d;
      --success: #00ffaa;
    }
    html, body { height: 100%; background: var(--bg); color: var(--text); font-family: 'Inter', 'Segoe UI', system-ui, sans-serif; -webkit-font-smoothing: antialiased; overflow-x: hidden; }
    body::before { content: ''; position: fixed; inset: 0; background-image: linear-gradient(rgba(0,210,255,0.03) 1px, transparent 1px), linear-gradient(90deg, rgba(0,210,255,0.03) 1px, transparent 1px); background-size: 60px 60px; pointer-events: none; z-index: 0; }
    body::after { content: ''; position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); width: 800px; height: 800px; background: radial-gradient(circle, rgba(0,210,255,0.04) 0%, transparent 70%); pointer-events: none; z-index: 0; }
    .page { position: relative; z-index: 1; min-height: 100vh; display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 2rem; }
    .logo { margin-bottom: 3rem; text-align: center; }
    .logo-icon { width: 56px; height: 56px; margin: 0 auto 1rem; border-radius: 50%; background: var(--accent-dim); border: 1px solid var(--border-hover); display: flex; align-items: center; justify-content: center; box-shadow: 0 0 30px var(--accent-glow), inset 0 0 20px rgba(0,210,255,0.05); animation: pulse 3s ease-in-out infinite; }
    @keyframes pulse { 0%, 100% { box-shadow: 0 0 20px var(--accent-glow), inset 0 0 15px rgba(0,210,255,0.05); } 50% { box-shadow: 0 0 40px rgba(0,210,255,0.4), inset 0 0 25px rgba(0,210,255,0.1); } }
    .logo-icon svg { width: 24px; height: 24px; }
    .logo h1 { font-size: 1.1rem; font-weight: 600; letter-spacing: 0.4em; color: var(--accent); text-transform: uppercase; }
    .logo p { font-size: 0.75rem; color: var(--text-dim); letter-spacing: 0.1em; margin-top: 0.3rem; }
    .card { width: 100%; max-width: 580px; background: var(--surface); border: 1px solid var(--border); border-radius: 16px; padding: 2rem; backdrop-filter: blur(20px); transition: border-color 0.3s; }
    .card:focus-within { border-color: var(--border-hover); }
    .input-group { display: flex; gap: 0.75rem; margin-bottom: 1.25rem; }
    .url-input { flex: 1; background: rgba(0,0,0,0.3); border: 1px solid var(--border); border-radius: 10px; padding: 0.85rem 1rem; color: var(--text); font-size: 0.9rem; outline: none; transition: border-color 0.2s, box-shadow 0.2s; font-family: inherit; }
    .url-input::placeholder { color: var(--text-dim); }
    .url-input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-dim); }
    .paste-btn { background: var(--accent-dim); border: 1px solid var(--border); border-radius: 10px; padding: 0.85rem 1rem; color: var(--accent); font-size: 0.8rem; font-weight: 500; letter-spacing: 0.05em; cursor: pointer; transition: all 0.2s; white-space: nowrap; font-family: inherit; }
    .paste-btn:hover { background: rgba(0,210,255,0.18); border-color: var(--accent); }
    .quality-row { display: flex; gap: 0.5rem; margin-bottom: 1.25rem; flex-wrap: wrap; }
    .quality-chip { padding: 0.4rem 0.9rem; border-radius: 20px; border: 1px solid var(--border); background: transparent; color: var(--text-dim); font-size: 0.78rem; font-weight: 500; cursor: pointer; transition: all 0.2s; font-family: inherit; }
    .quality-chip:hover { border-color: var(--accent); color: var(--accent); }
    .quality-chip.active { background: var(--accent-dim); border-color: var(--accent); color: var(--accent); }
    .download-btn { width: 100%; padding: 1rem; background: linear-gradient(135deg, rgba(0,210,255,0.15), rgba(0,210,255,0.05)); border: 1px solid var(--accent); border-radius: 10px; color: var(--accent); font-size: 0.95rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; cursor: pointer; transition: all 0.2s; font-family: inherit; position: relative; overflow: hidden; }
    .download-btn::before { content: ''; position: absolute; inset: 0; background: linear-gradient(135deg, rgba(0,210,255,0.2), transparent); opacity: 0; transition: opacity 0.2s; }
    .download-btn:hover:not(:disabled)::before { opacity: 1; }
    .download-btn:hover:not(:disabled) { box-shadow: 0 0 25px rgba(0,210,255,0.2); }
    .download-btn:disabled { opacity: 0.5; cursor: not-allowed; }
    .video-info { display: none; margin-bottom: 1.25rem; gap: 0.75rem; align-items: center; padding: 0.75rem; background: rgba(0,0,0,0.2); border-radius: 10px; border: 1px solid var(--border); }
    .video-info.visible { display: flex; }
    .video-thumb { width: 80px; height: 50px; object-fit: cover; border-radius: 6px; flex-shrink: 0; }
    .video-meta { min-width: 0; }
    .video-title { font-size: 0.85rem; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .video-sub { font-size: 0.72rem; color: var(--text-dim); margin-top: 0.2rem; }
    .status { margin-top: 1rem; font-size: 0.8rem; text-align: center; min-height: 1.2em; transition: all 0.3s; }
    .status.loading { color: var(--accent); }
    .status.error { color: var(--error); }
    .status.success { color: var(--success); }
    .loader-bar { height: 2px; background: var(--border); border-radius: 2px; margin-top: 0.75rem; overflow: hidden; opacity: 0; transition: opacity 0.3s; }
    .loader-bar.active { opacity: 1; }
    .loader-fill { height: 100%; background: linear-gradient(90deg, transparent, var(--accent), transparent); background-size: 200% 100%; animation: shimmer 1.5s infinite; width: 100%; }
    @keyframes shimmer { 0% { background-position: -200% 0; } 100% { background-position: 200% 0; } }
    .platforms { margin-top: 2rem; text-align: center; }
    .platforms p { font-size: 0.7rem; color: var(--text-dim); letter-spacing: 0.08em; text-transform: uppercase; margin-bottom: 0.6rem; }
    .platform-tags { display: flex; gap: 0.5rem; justify-content: center; flex-wrap: wrap; }
    .platform-tag { font-size: 0.72rem; color: var(--text-dim); padding: 0.25rem 0.6rem; border: 1px solid rgba(255,255,255,0.07); border-radius: 20px; }
  </style>
</head>
<body>
  <div class="page">
    <div class="logo">
      <div class="logo-icon">
        <svg viewBox="0 0 24 24" fill="none" stroke="#00d2ff" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="12" cy="12" r="9"/>
          <path d="M12 7v5l3 3"/>
          <circle cx="12" cy="12" r="2" fill="#00d2ff" stroke="none"/>
        </svg>
      </div>
      <h1>VOID</h1>
      <p>Video Downloader</p>
    </div>
    <div class="card">
      <div class="input-group">
        <input class="url-input" id="urlInput" type="text" placeholder="Link hier einfügen..." autocomplete="off" spellcheck="false" />
        <button class="paste-btn" id="pasteBtn">Einfügen</button>
      </div>
      <div class="quality-row" id="qualityRow">
        <button class="quality-chip active" data-quality="best">Best</button>
        <button class="quality-chip" data-quality="1080">1080p</button>
        <button class="quality-chip" data-quality="720">720p</button>
        <button class="quality-chip" data-quality="480">480p</button>
        <button class="quality-chip" data-quality="audio">Audio only</button>
      </div>
      <div class="video-info" id="videoInfo">
        <img class="video-thumb" id="videoThumb" src="" alt="" />
        <div class="video-meta">
          <div class="video-title" id="videoTitle"></div>
          <div class="video-sub" id="videoSub"></div>
        </div>
      </div>
      <button class="download-btn" id="downloadBtn">Download starten</button>
      <div class="loader-bar" id="loaderBar"><div class="loader-fill"></div></div>
      <div class="status" id="status"></div>
    </div>
    <div class="platforms">
      <p>Unterstützte Plattformen</p>
      <div class="platform-tags">
        <span class="platform-tag">TikTok</span>
        <span class="platform-tag">Instagram</span>
        <span class="platform-tag">YouTube</span>
        <span class="platform-tag">Twitter / X</span>
        <span class="platform-tag">Reddit</span>
        <span class="platform-tag">+ 1000 mehr</span>
      </div>
    </div>
  </div>
  <script>
    const urlInput = document.getElementById('urlInput');
    const pasteBtn = document.getElementById('pasteBtn');
    const downloadBtn = document.getElementById('downloadBtn');
    const statusEl = document.getElementById('status');
    const loaderBar = document.getElementById('loaderBar');
    const videoInfo = document.getElementById('videoInfo');
    const videoThumb = document.getElementById('videoThumb');
    const videoTitle = document.getElementById('videoTitle');
    const videoSub = document.getElementById('videoSub');
    let selectedQuality = 'best';
    let infoTimeout = null;
    document.querySelectorAll('.quality-chip').forEach(chip => {
      chip.addEventListener('click', () => {
        document.querySelectorAll('.quality-chip').forEach(c => c.classList.remove('active'));
        chip.classList.add('active');
        selectedQuality = chip.dataset.quality;
      });
    });
    pasteBtn.addEventListener('click', async () => {
      try {
        const text = await navigator.clipboard.readText();
        urlInput.value = text;
        urlInput.dispatchEvent(new Event('input'));
      } catch { urlInput.focus(); }
    });
    urlInput.addEventListener('input', () => {
      const url = urlInput.value.trim();
      clearTimeout(infoTimeout);
      videoInfo.classList.remove('visible');
      setStatus('', '');
      if (url.startsWith('http')) {
        infoTimeout = setTimeout(() => fetchInfo(url), 800);
      }
    });
    async function fetchInfo(url) {
      setStatus('Analysiere Link...', 'loading');
      try {
        const res = await fetch('/api/info', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ url }) });
        if (!res.ok) throw new Error('Link nicht erkannt');
        const data = await res.json();
        if (data.thumbnail) { videoThumb.src = data.thumbnail; videoThumb.style.display = 'block'; } else { videoThumb.style.display = 'none'; }
        videoTitle.textContent = data.title || 'Video';
        const dur = data.duration ? formatDuration(data.duration) : '';
        videoSub.textContent = [data.platform, data.uploader, dur].filter(Boolean).join(' · ');
        videoInfo.classList.add('visible');
        setStatus('', '');
      } catch (e) { setStatus(e.message, 'error'); }
    }
    downloadBtn.addEventListener('click', async () => {
      const url = urlInput.value.trim();
      if (!url) { setStatus('Bitte einen Link eingeben.', 'error'); return; }
      setLoading(true);
      setStatus('Download läuft...', 'loading');
      try {
        const res = await fetch('/api/download', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ url, quality: selectedQuality }) });
        if (!res.ok) { const err = await res.json(); throw new Error(err.detail || 'Download fehlgeschlagen'); }
        const blob = await res.blob();
        const disposition = res.headers.get('Content-Disposition') || '';
        const nameMatch = disposition.match(/filename="?([^"]+)"?/);
        const filename = nameMatch ? nameMatch[1] : 'video.mp4';
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = filename;
        a.click();
        URL.revokeObjectURL(a.href);
        setStatus('Erfolgreich heruntergeladen.', 'success');
      } catch (e) { setStatus(e.message, 'error'); }
      finally { setLoading(false); }
    });
    function setLoading(active) { downloadBtn.disabled = active; loaderBar.classList.toggle('active', active); downloadBtn.textContent = active ? 'Wird verarbeitet...' : 'Download starten'; }
    function setStatus(msg, type) { statusEl.textContent = msg; statusEl.className = 'status' + (type ? ' ' + type : ''); }
    function formatDuration(secs) { const m = Math.floor(secs / 60); const s = secs % 60; return `${m}:${String(s).padStart(2, '0')}`; }
  </script>
</body>
</html>
HTMLEOF

echo "==> Systemd Service einrichten..."
cat > /etc/systemd/system/void.service << 'SVCEOF'
[Unit]
Description=VOID Video Downloader
After=network.target

[Service]
WorkingDirectory=/opt/void
ExecStart=/usr/local/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable void
systemctl restart void
sleep 2

STATUS=$(systemctl is-active void)
echo "==> Service Status: $STATUS"

# Firewall
ufw allow 8000/tcp 2>/dev/null || true

echo ""
echo "============================================"
echo "  FERTIG! App laeuft auf:"
echo "  http://178.104.19.150:8000"
echo "============================================"

import json
import os
import time
from datetime import date
from typing import Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import database as db
from ai_identify import identify_part, _MODEL

app = FastAPI(title="LEGO Sorting Catalog")

db.init_db()

# ── Active model (mutable at runtime) ─────────────────────────────────────────
_active_model: str = _MODEL

# ── Bedrock model list (cached) ────────────────────────────────────────────────
_MODELS_CACHE: dict = {}
_CACHE_TTL = 300  # seconds

_FALLBACK_MODELS = [
    {"id": "us.anthropic.claude-haiku-4-5-20251001-v1:0",  "label": "Claude Haiku 4.5 (fast / cheap)"},
    {"id": "us.anthropic.claude-sonnet-4-5-20250929-v1:0", "label": "Claude Sonnet 4.5"},
    {"id": "us.anthropic.claude-opus-4-5-20251001-v1:0",   "label": "Claude Opus 4.5 (most capable)"},
]


def _fetch_inference_profiles() -> list[dict]:
    import boto3
    aws_region = os.environ.get("AWS_REGION", "us-east-1")
    bedrock = boto3.client("bedrock", region_name=aws_region)
    profiles = []
    kwargs: dict = {"typeEquals": "SYSTEM_DEFINED"}
    while True:
        resp = bedrock.list_inference_profiles(**kwargs)
        for p in resp.get("inferenceProfileSummaries", []):
            if p.get("status") != "ACTIVE":
                continue
            pid = p.get("inferenceProfileId", "")
            if "anthropic" not in pid:
                continue
            name = p.get("inferenceProfileName", pid)
            profiles.append({"id": pid, "label": name})
        next_token = resp.get("nextToken")
        if not next_token:
            break
        kwargs["nextToken"] = next_token
    return profiles


def _get_models() -> list[dict]:
    now = time.monotonic()
    if _MODELS_CACHE.get("expires", 0) > now:
        return _MODELS_CACHE["models"]
    try:
        models = _fetch_inference_profiles()
        if models:
            _MODELS_CACHE["models"] = models
            _MODELS_CACHE["expires"] = now + _CACHE_TTL
            return models
    except Exception:
        pass
    return _FALLBACK_MODELS


# ── Static files ──────────────────────────────────────────────────────────────
app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/")
def index():
    return FileResponse("static/index.html")


# ── Pydantic models ───────────────────────────────────────────────────────────

class DrawerCreate(BaseModel):
    cabinet: int
    row: str
    col: int
    label: Optional[str] = None
    notes: Optional[str] = None


class PartCreate(BaseModel):
    part_num: str
    part_name: str
    category: Optional[str] = None
    drawer_id: Optional[int] = None
    notes: Optional[str] = None
    ai_description: Optional[str] = None


class PartUpdate(BaseModel):
    part_name: Optional[str] = None
    category: Optional[str] = None
    drawer_id: Optional[int] = None
    notes: Optional[str] = None


# ── Models / Settings endpoints ───────────────────────────────────────────────

@app.get("/api/models")
def list_models():
    return {"provider": "bedrock", "active": _active_model, "available": _get_models()}


class SettingsUpdate(BaseModel):
    model_id: str


@app.put("/api/settings")
def update_settings(body: SettingsUpdate):
    global _active_model
    _active_model = body.model_id.strip()
    return {"provider": _PROVIDER, "active": _active_model}


# ── Brick Architect lookup ────────────────────────────────────────────────────

@app.get("/api/lookup/{part_num}")
async def lookup_part(part_num: str):
    """Fetch part name from Brick Architect and check local catalog."""
    import httpx, re as _re
    ba_url = f"https://brickarchitect.com/parts/{part_num}"
    name = None
    found = False

    try:
        async with httpx.AsyncClient(timeout=8) as http:
            resp = await http.get(ba_url, follow_redirects=True)
            if resp.status_code == 200:
                # Title format: "3710 - 1×4 Plate - LEGO Parts Guide - Brick Architect"
                m = _re.search(r"<title>([^<]+)</title>", resp.text, _re.IGNORECASE)
                if m:
                    parts = m.group(1).split(" - ")
                    if len(parts) >= 2:
                        name = parts[1].strip()
                        found = True
    except Exception:
        pass

    # Check local catalog
    with db.db() as conn:
        existing = db.get_part(conn, part_num)

    return {
        "part_num": part_num,
        "name": name,
        "found_on_brickarchitect": found,
        "brickarchitect_url": ba_url,
        "existing": existing,
    }


# ── Identify endpoint ─────────────────────────────────────────────────────────

@app.post("/api/identify")
async def identify(file: UploadFile = File(...)):
    content_type = file.content_type or "image/jpeg"
    image_bytes = await file.read()

    ai_result = identify_part(image_bytes, media_type=content_type, model_id=_active_model)

    # Check if already cataloged
    existing = None
    if ai_result.get("part_num"):
        with db.db() as conn:
            existing = db.get_part(conn, ai_result["part_num"])

    location = None
    if existing and existing.get("drawer_id"):
        location = {
            "drawer_id": existing["drawer_id"],
            "cabinet": existing["cabinet"],
            "row": existing["row"],
            "col": existing["col"],
            "label": existing.get("drawer_label"),
            "display": f"Cabinet {existing['cabinet']} · {existing['row']}{existing['col']}",
        }

    return {
        "ai": ai_result,
        "existing": existing,
        "location": location,
    }


# ── Parts endpoints ───────────────────────────────────────────────────────────

@app.get("/api/parts")
def list_parts(q: str = ""):
    with db.db() as conn:
        if q:
            parts = db.search_parts(conn, q)
        else:
            parts = db.list_parts(conn)
    return parts


@app.get("/api/parts/{part_num}")
def get_part(part_num: str):
    with db.db() as conn:
        part = db.get_part(conn, part_num)
    if not part:
        raise HTTPException(status_code=404, detail="Part not found")
    return part


@app.post("/api/parts", status_code=201)
def create_part(body: PartCreate):
    with db.db() as conn:
        part = db.upsert_part(
            conn,
            part_num=body.part_num,
            part_name=body.part_name,
            category=body.category,
            drawer_id=body.drawer_id,
            notes=body.notes,
            ai_description=body.ai_description,
        )
    return part


@app.put("/api/parts/{part_num}")
def update_part(part_num: str, body: PartUpdate):
    with db.db() as conn:
        existing = db.get_part(conn, part_num)
        if not existing:
            raise HTTPException(status_code=404, detail="Part not found")
        part = db.update_part(conn, part_num, **body.model_dump(exclude_none=True))
    return part


# ── Drawers endpoints ─────────────────────────────────────────────────────────

@app.get("/api/drawers")
def list_drawers():
    with db.db() as conn:
        drawers = db.list_drawers(conn)
    return drawers


@app.post("/api/drawers", status_code=201)
def create_drawer(body: DrawerCreate):
    with db.db() as conn:
        drawer = db.create_drawer(conn, body.cabinet, body.row, body.col, body.label, body.notes)
    return drawer


@app.get("/api/drawers/{drawer_id}/parts")
def get_drawer_parts(drawer_id: int):
    with db.db() as conn:
        drawer = db.get_drawer_by_id(conn, drawer_id)
        if not drawer:
            raise HTTPException(status_code=404, detail="Drawer not found")
        parts = db.get_drawer_parts(conn, drawer_id)
    return {"drawer": drawer, "parts": parts}


# ── Parts catalog (Rebrickable) ───────────────────────────────────────────────

@app.get("/api/catalog/search")
def catalog_search(q: str = ""):
    if not q or len(q) < 2:
        return []
    with db.db() as conn:
        return db.search_catalog(conn, q)


@app.post("/api/catalog/load")
async def catalog_load():
    """Download parts.csv from Rebrickable and populate parts_catalog table."""
    import csv, gzip, io, httpx
    url = "https://cdn.rebrickable.com/media/downloads/parts.csv.gz"
    async with httpx.AsyncClient(timeout=30) as http:
        resp = await http.get(url)
        resp.raise_for_status()

    reader = csv.DictReader(io.TextIOWrapper(gzip.open(io.BytesIO(resp.content)), encoding="utf-8"))
    rows = [(r["part_num"], r["name"], r.get("part_cat_id"), r.get("part_material")) for r in reader]

    with db.db() as conn:
        conn.execute("DELETE FROM parts_catalog")
        conn.executemany(
            "INSERT OR REPLACE INTO parts_catalog (part_num, name, part_cat_id, part_material) VALUES (?,?,?,?)",
            rows,
        )
        count = db.catalog_count(conn)

    return {"status": "ok", "parts_loaded": count}


@app.get("/api/catalog/status")
def catalog_status():
    with db.db() as conn:
        count = db.catalog_count(conn)
    return {"parts_in_catalog": count}


# ── Export / Import ───────────────────────────────────────────────────────────

@app.get("/api/export")
def export_catalog():
    with db.db() as conn:
        data = db.export_all(conn)
    filename = f"lego-catalog-{date.today()}.json"
    # Write to temp file and send
    import tempfile, os
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(data, f, indent=2, default=str)
        tmp_path = f.name
    return FileResponse(
        tmp_path,
        media_type="application/json",
        filename=filename,
        background=None,
    )


@app.post("/api/import")
async def import_catalog(file: UploadFile = File(...)):
    content = await file.read()
    try:
        data = json.loads(content)
    except json.JSONDecodeError as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON: {e}")

    if not isinstance(data, dict) or "parts" not in data:
        raise HTTPException(status_code=400, detail="Invalid catalog format")

    with db.db() as conn:
        db.import_data(conn, data)
        parts_count = len(conn.execute("SELECT 1 FROM part_locations").fetchall())
        drawers_count = len(conn.execute("SELECT 1 FROM drawers").fetchall())

    return {
        "status": "ok",
        "parts": parts_count,
        "drawers": drawers_count,
    }

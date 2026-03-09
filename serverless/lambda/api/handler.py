import json
import os
import time
import uuid
from datetime import date
from typing import Optional

import boto3
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import Response
from mangum import Mangum
from pydantic import BaseModel

import database as db
from ai_identify import identify_part, _MODEL

app = FastAPI(title="LEGO Sorting Catalog")

IMAGES_BUCKET = os.environ.get("IMAGES_BUCKET", "")
COGNITO_USER_POOL_ID = os.environ.get("COGNITO_USER_POOL_ID", "")
COGNITO_CLIENT_ID = os.environ.get("COGNITO_CLIENT_ID", "")
_region = os.environ.get("AWS_REGION", "us-east-1")
_s3 = boto3.client("s3", region_name=_region)
_cognito = boto3.client("cognito-idp", region_name=_region)

# ── Active model ──────────────────────────────────────────────────────────────
_active_model: str = _MODEL

# ── Bedrock model list (cached) ───────────────────────────────────────────────
_MODELS_CACHE: dict = {}
_CACHE_TTL = 300

_FALLBACK_MODELS = [
    {"id": "us.anthropic.claude-haiku-4-5-20251001-v1:0",  "label": "Claude Haiku 4.5 (fast / cheap)"},
    {"id": "us.anthropic.claude-sonnet-4-5-20250929-v1:0", "label": "Claude Sonnet 4.5"},
    {"id": "anthropic.claude-3-haiku-20240307-v1:0",       "label": "Claude 3 Haiku"},
]

_VISION_MODEL_PATTERNS = [
    "claude-3-haiku", "claude-3-sonnet", "claude-3-opus",
    "claude-3-5-sonnet", "claude-haiku-4", "claude-sonnet-4", "claude-opus-4",
]


def _supports_vision(model_id: str) -> bool:
    mid = model_id.lower()
    return any(p in mid for p in _VISION_MODEL_PATTERNS)


def _fetch_inference_profiles() -> list[dict]:
    bedrock = boto3.client("bedrock", region_name=_region)
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
            if not _supports_vision(pid):
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


# ── Auth / membership dependencies ────────────────────────────────────────────

def get_current_user(request: Request) -> dict:
    """Extract user info from JWT claims set by API Gateway JWT authorizer."""
    try:
        claims = request.scope["aws.event"]["requestContext"]["authorizer"]["jwt"]["claims"]
        return {
            "user_id": claims["sub"],
            "email": claims.get("email"),  # present in ID tokens, not always in access tokens
        }
    except (KeyError, TypeError):
        raise HTTPException(status_code=401, detail="Unauthorized")


def _get_user_email(user_id: str) -> str:
    """Look up the user's email in Cognito by their sub."""
    try:
        resp = _cognito.list_users(
            UserPoolId=COGNITO_USER_POOL_ID,
            Filter=f'sub = "{user_id}"',
            Limit=1,
        )
        users = resp.get("Users", [])
        if users:
            for attr in users[0].get("Attributes", []):
                if attr["Name"] == "email":
                    return attr["Value"]
    except Exception:
        pass
    return user_id  # fallback to sub if lookup fails


def verify_member(project_id: str, user: dict = Depends(get_current_user)) -> str:
    """Verify the current user is a member of the project; return user_id."""
    if not db.is_member(project_id, user["user_id"]):
        raise HTTPException(status_code=403, detail="Not a member of this project")
    return user["user_id"]


# ── Pydantic models ───────────────────────────────────────────────────────────

class ProjectCreate(BaseModel):
    name: str


class MemberAdd(BaseModel):
    email: str


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
    drawer_id: Optional[str] = None
    notes: Optional[str] = None
    ai_description: Optional[str] = None


class PartUpdate(BaseModel):
    part_name: Optional[str] = None
    category: Optional[str] = None
    drawer_id: Optional[str] = None
    notes: Optional[str] = None


class SettingsUpdate(BaseModel):
    model_id: str


class UploadRequest(BaseModel):
    content_type: str = "image/jpeg"


class IdentifyRequest(BaseModel):
    s3_key: str


# ── Config (unauthenticated) ──────────────────────────────────────────────────

@app.get("/api/config")
def get_config():
    """Returns Cognito config needed by the frontend login form. No auth required."""
    return {
        "user_pool_id": COGNITO_USER_POOL_ID,
        "client_id": COGNITO_CLIENT_ID,
        "region": _region,
    }


# ── Models / Settings ─────────────────────────────────────────────────────────

@app.get("/api/models")
def list_models():
    return {"provider": "bedrock", "active": _active_model, "available": _get_models()}


@app.put("/api/settings")
def update_settings(body: SettingsUpdate):
    global _active_model
    _active_model = body.model_id.strip()
    return {"provider": "bedrock", "active": _active_model}


# ── Image upload (presigned S3 PUT) — not project-scoped ─────────────────────

@app.post("/api/images/upload")
def get_upload_url(body: UploadRequest, user: dict = Depends(get_current_user)):
    """Return a presigned S3 PUT URL. Client uploads image directly to S3."""
    s3_key = f"uploads/{uuid.uuid4()}.jpg"
    presigned_url = _s3.generate_presigned_url(
        "put_object",
        Params={
            "Bucket": IMAGES_BUCKET,
            "Key": s3_key,
            "ContentType": body.content_type,
        },
        ExpiresIn=300,
    )
    return {"upload_url": presigned_url, "s3_key": s3_key}


# ── Parts catalog (Rebrickable, stored in S3) — not project-scoped ────────────

@app.get("/api/catalog/search")
def catalog_search(q: str = "", user: dict = Depends(get_current_user)):
    if not q or len(q) < 2:
        return []
    return db.search_catalog(q)


@app.post("/api/catalog/load")
async def catalog_load(user: dict = Depends(get_current_user)):
    """Download Rebrickable parts catalog and store in S3."""
    import gzip as _gzip
    import io as _io
    import csv as _csv
    import httpx

    url = "https://cdn.rebrickable.com/media/downloads/parts.csv.gz"
    async with httpx.AsyncClient(timeout=55) as http:
        resp = await http.get(url)
        resp.raise_for_status()

    raw_gz = resp.content
    reader = _csv.DictReader(
        _io.TextIOWrapper(_gzip.open(_io.BytesIO(raw_gz)), encoding="utf-8")
    )
    count = sum(1 for _ in reader)

    _s3.put_object(
        Bucket=db.CATALOG_BUCKET,
        Key="parts.csv.gz",
        Body=raw_gz,
        ContentType="application/gzip",
    )
    _s3.put_object(
        Bucket=db.CATALOG_BUCKET,
        Key="catalog_meta.json",
        Body=json.dumps({"count": count}).encode(),
        ContentType="application/json",
    )

    db._catalog_loaded = False
    db._load_catalog()

    return {"status": "ok", "parts_loaded": count}


@app.get("/api/catalog/status")
def catalog_status(user: dict = Depends(get_current_user)):
    return {"parts_in_catalog": db.catalog_count()}


# ── Projects ──────────────────────────────────────────────────────────────────

@app.get("/api/projects")
def list_projects(user: dict = Depends(get_current_user)):
    return db.list_user_projects(user["user_id"])


@app.post("/api/projects", status_code=201)
def create_project(body: ProjectCreate, user: dict = Depends(get_current_user)):
    email = user.get("email") or _get_user_email(user["user_id"])
    return db.create_project(body.name, user["user_id"], email)


@app.get("/api/projects/{project_id}")
def get_project(project_id: str, user_id: str = Depends(verify_member)):
    proj = db.get_project(project_id)
    if not proj:
        raise HTTPException(status_code=404, detail="Project not found")
    members = db.list_members(project_id)
    return {**proj, "members": members}


# ── Project members ───────────────────────────────────────────────────────────

@app.post("/api/projects/{project_id}/members", status_code=201)
def add_member(project_id: str, body: MemberAdd, user_id: str = Depends(verify_member)):
    """Add a member by email. The invited user must already have a Cognito account."""
    email = body.email.strip().lower()
    try:
        resp = _cognito.list_users(
            UserPoolId=COGNITO_USER_POOL_ID,
            Filter=f'email = "{email}"',
            Limit=1,
        )
        users = resp.get("Users", [])
        if not users:
            raise HTTPException(status_code=404, detail=f"No user found with email {email}")
        invited_user_id = next(
            (a["Value"] for a in users[0].get("Attributes", []) if a["Name"] == "sub"),
            None,
        )
        if not invited_user_id:
            raise HTTPException(status_code=404, detail="Could not resolve user")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Cognito lookup failed: {e}")

    if db.is_member(project_id, invited_user_id):
        raise HTTPException(status_code=409, detail="User is already a member")

    return db.add_member(project_id, invited_user_id, email)


@app.delete("/api/projects/{project_id}/members/{target_user_id}", status_code=204)
def remove_member(project_id: str, target_user_id: str, user_id: str = Depends(verify_member)):
    db.remove_member(project_id, target_user_id)


# ── Drawers ───────────────────────────────────────────────────────────────────

@app.get("/api/projects/{project_id}/drawers")
def list_drawers(project_id: str, user_id: str = Depends(verify_member)):
    return db.list_drawers(project_id)


@app.post("/api/projects/{project_id}/drawers", status_code=201)
def create_drawer(project_id: str, body: DrawerCreate, user_id: str = Depends(verify_member)):
    return db.create_drawer(project_id, body.cabinet, body.row, body.col, body.label, body.notes)


@app.get("/api/projects/{project_id}/drawers/{drawer_id}/parts")
def get_drawer_parts(project_id: str, drawer_id: str, user_id: str = Depends(verify_member)):
    drawer = db.get_drawer_by_id(drawer_id)
    if not drawer or drawer.get("project_id") != project_id:
        raise HTTPException(status_code=404, detail="Drawer not found")
    parts = db.get_drawer_parts(project_id, drawer_id)
    return {"drawer": drawer, "parts": parts}


# ── Parts ─────────────────────────────────────────────────────────────────────

@app.get("/api/projects/{project_id}/parts")
def list_parts(project_id: str, q: str = "", user_id: str = Depends(verify_member)):
    if q:
        return db.search_parts(project_id, q)
    return db.list_parts(project_id)


@app.get("/api/projects/{project_id}/parts/{part_num}")
def get_part(project_id: str, part_num: str, user_id: str = Depends(verify_member)):
    part = db.get_part(project_id, part_num)
    if not part:
        raise HTTPException(status_code=404, detail="Part not found")
    return part


@app.post("/api/projects/{project_id}/parts", status_code=201)
def create_part(project_id: str, body: PartCreate, user_id: str = Depends(verify_member)):
    return db.upsert_part(
        project_id=project_id,
        part_num=body.part_num,
        part_name=body.part_name,
        category=body.category,
        drawer_id=body.drawer_id,
        notes=body.notes,
        ai_description=body.ai_description,
    )


@app.put("/api/projects/{project_id}/parts/{part_num}")
def update_part(project_id: str, part_num: str, body: PartUpdate, user_id: str = Depends(verify_member)):
    if not db.get_part(project_id, part_num):
        raise HTTPException(status_code=404, detail="Part not found")
    return db.update_part(project_id, part_num, **body.model_dump(exclude_none=True))


# ── Identify ──────────────────────────────────────────────────────────────────

@app.post("/api/projects/{project_id}/identify")
def identify(project_id: str, body: IdentifyRequest, user_id: str = Depends(verify_member)):
    """Read image from S3, send to Bedrock, return identification + drawer lookup."""
    resp = _s3.get_object(Bucket=IMAGES_BUCKET, Key=body.s3_key)
    image_bytes = resp["Body"].read()
    content_type = resp.get("ContentType", "image/jpeg")

    ai_result = identify_part(image_bytes, media_type=content_type, model_id=_active_model)

    existing = None
    if ai_result.get("part_num"):
        existing = db.get_part(project_id, ai_result["part_num"])

    location = None
    if existing and existing.get("drawer_id"):
        location = {
            "drawer_id": existing["drawer_id"],
            "cabinet": existing.get("cabinet"),
            "row": existing.get("row"),
            "col": existing.get("col"),
            "label": existing.get("drawer_label"),
            "display": f"Cabinet {existing['cabinet']} · {existing['row']}{existing['col']}",
        }

    return {"ai": ai_result, "existing": existing, "location": location}


# ── Brick Architect lookup ────────────────────────────────────────────────────

@app.get("/api/projects/{project_id}/lookup/{part_num}")
async def lookup_part(project_id: str, part_num: str, user_id: str = Depends(verify_member)):
    import httpx
    import re as _re
    ba_url = f"https://brickarchitect.com/parts/{part_num}"
    name = None
    found = False
    try:
        async with httpx.AsyncClient(timeout=8) as http:
            resp = await http.get(ba_url, follow_redirects=True)
            if resp.status_code == 200:
                m = _re.search(r"<title>([^<]+)</title>", resp.text, _re.IGNORECASE)
                if m:
                    parts = m.group(1).split(" - ")
                    if len(parts) >= 2:
                        name = parts[1].strip()
                        found = True
    except Exception:
        pass

    existing = db.get_part(project_id, part_num)
    return {
        "part_num": part_num,
        "name": name,
        "found_on_brickarchitect": found,
        "brickarchitect_url": ba_url,
        "existing": existing,
    }


# ── Export / Import ───────────────────────────────────────────────────────────

@app.get("/api/projects/{project_id}/export")
def export_catalog(project_id: str, user_id: str = Depends(verify_member)):
    data = db.export_all(project_id)
    filename = f"lego-catalog-{date.today()}.json"
    content = json.dumps(data, indent=2, default=str)
    return Response(
        content=content,
        media_type="application/json",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@app.post("/api/projects/{project_id}/import")
async def import_catalog(project_id: str, request: Request, user_id: str = Depends(verify_member)):
    try:
        data = await request.json()
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON: {e}")

    if not isinstance(data, dict) or "parts" not in data:
        raise HTTPException(status_code=400, detail="Invalid catalog format")

    db.import_data(project_id, data)
    all_parts = db.list_parts(project_id)
    all_drawers = db.list_drawers(project_id)
    return {"status": "ok", "parts": len(all_parts), "drawers": len(all_drawers)}


# ── Lambda entry point ────────────────────────────────────────────────────────
handler = Mangum(app, lifespan="off")

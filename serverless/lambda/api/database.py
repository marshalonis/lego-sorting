import csv
import gzip
import io
import json
import os
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Optional

import boto3
from boto3.dynamodb.conditions import Key

_region = os.environ.get("AWS_REGION", "us-east-1")
_dynamodb = boto3.resource("dynamodb", region_name=_region)
_s3 = boto3.client("s3", region_name=_region)

DRAWERS_TABLE = os.environ.get("DRAWERS_TABLE", "lego-drawers")
PARTS_TABLE = os.environ.get("PARTS_TABLE", "lego-parts")
PROJECTS_TABLE = os.environ.get("PROJECTS_TABLE", "lego-projects")
MEMBERS_TABLE = os.environ.get("MEMBERS_TABLE", "lego-project-members")
CATALOG_BUCKET = os.environ.get("CATALOG_BUCKET", "")

_drawers_table = _dynamodb.Table(DRAWERS_TABLE)
_parts_table = _dynamodb.Table(PARTS_TABLE)
_projects_table = _dynamodb.Table(PROJECTS_TABLE)
_members_table = _dynamodb.Table(MEMBERS_TABLE)


# ── Decimal conversion ────────────────────────────────────────────────────────

def _to_python(obj):
    """Recursively convert DynamoDB Decimal to int/float for JSON serialization."""
    if isinstance(obj, Decimal):
        return int(obj) if obj % 1 == 0 else float(obj)
    if isinstance(obj, dict):
        return {k: _to_python(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_to_python(i) for i in obj]
    return obj


def _query_all(table, **kwargs) -> list:
    """Paginate through all items in a DynamoDB query."""
    items = []
    resp = table.query(**kwargs)
    items.extend(resp.get("Items", []))
    while "LastEvaluatedKey" in resp:
        resp = table.query(ExclusiveStartKey=resp["LastEvaluatedKey"], **kwargs)
        items.extend(resp.get("Items", []))
    return items


def _location_key(project_id: str, cabinet: int, row: str, col: int) -> str:
    return f"{project_id}#{cabinet}#{row.upper()}#{col}"


# ── Project helpers ────────────────────────────────────────────────────────────

def create_project(name: str, user_id: str, user_email: str) -> dict:
    project_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    item = {
        "project_id": project_id,
        "name": name,
        "created_by": user_id,
        "created_at": now,
    }
    _projects_table.put_item(Item=item)
    # Auto-add creator as member
    _members_table.put_item(Item={
        "project_id": project_id,
        "user_id": user_id,
        "email": user_email,
        "added_at": now,
    })
    return item


def get_project(project_id: str) -> Optional[dict]:
    resp = _projects_table.get_item(Key={"project_id": project_id})
    item = resp.get("Item")
    return _to_python(item) if item else None


def list_user_projects(user_id: str) -> list[dict]:
    """List all projects the user is a member of."""
    memberships = _query_all(
        _members_table,
        IndexName="user-index",
        KeyConditionExpression=Key("user_id").eq(user_id),
    )
    projects = []
    for m in memberships:
        proj = get_project(m["project_id"])
        if proj:
            projects.append(proj)
    return sorted(projects, key=lambda p: p.get("created_at", ""))


def is_member(project_id: str, user_id: str) -> bool:
    resp = _members_table.get_item(Key={"project_id": project_id, "user_id": user_id})
    return "Item" in resp


def add_member(project_id: str, user_id: str, user_email: str) -> dict:
    now = datetime.now(timezone.utc).isoformat()
    item = {
        "project_id": project_id,
        "user_id": user_id,
        "email": user_email,
        "added_at": now,
    }
    _members_table.put_item(Item=item)
    return _to_python(item)


def remove_member(project_id: str, user_id: str):
    _members_table.delete_item(Key={"project_id": project_id, "user_id": user_id})


def list_members(project_id: str) -> list[dict]:
    resp = _members_table.query(
        KeyConditionExpression=Key("project_id").eq(project_id),
    )
    return _to_python(resp.get("Items", []))


# ── Drawer helpers ────────────────────────────────────────────────────────────

def create_drawer(project_id: str, cabinet: int, row: str, col: int,
                  label: str = None, notes: str = None) -> dict:
    existing = get_drawer_by_location(project_id, cabinet, row, col)
    if existing:
        update_parts = []
        names = {}
        values = {}
        if label is not None:
            update_parts.append("#lbl = :label")
            names["#lbl"] = "label"
            values[":label"] = label
        if notes is not None:
            update_parts.append("#nts = :notes")
            names["#nts"] = "notes"
            values[":notes"] = notes
        if update_parts:
            _drawers_table.update_item(
                Key={"id": existing["id"]},
                UpdateExpression="SET " + ", ".join(update_parts),
                ExpressionAttributeNames=names,
                ExpressionAttributeValues=values,
            )
        return _to_python(get_drawer_by_id(existing["id"]))

    item = {
        "id": str(uuid.uuid4()),
        "project_id": project_id,
        "cabinet": cabinet,
        "row": row.upper(),
        "col": col,
        "location_key": _location_key(project_id, cabinet, row, col),
    }
    if label is not None:
        item["label"] = label
    if notes is not None:
        item["notes"] = notes
    _drawers_table.put_item(Item=item)
    return _to_python(item)


def get_drawer_by_id(drawer_id: str) -> Optional[dict]:
    resp = _drawers_table.get_item(Key={"id": drawer_id})
    item = resp.get("Item")
    return _to_python(item) if item else None


def get_drawer_by_location(project_id: str, cabinet: int, row: str, col: int) -> Optional[dict]:
    key = _location_key(project_id, cabinet, row, col)
    resp = _drawers_table.query(
        IndexName="location-index",
        KeyConditionExpression=Key("location_key").eq(key),
    )
    items = resp.get("Items", [])
    return _to_python(items[0]) if items else None


def _get_drawers_map(project_id: str) -> dict:
    drawers = _to_python(_query_all(
        _drawers_table,
        IndexName="project-index",
        KeyConditionExpression=Key("project_id").eq(project_id),
    ))
    return {d["id"]: d for d in drawers}


def list_drawers(project_id: str) -> list[dict]:
    drawers = _to_python(_query_all(
        _drawers_table,
        IndexName="project-index",
        KeyConditionExpression=Key("project_id").eq(project_id),
    ))
    parts = _to_python(_query_all(
        _parts_table,
        KeyConditionExpression=Key("project_id").eq(project_id),
        ProjectionExpression="part_num, drawer_id",
    ))

    drawer_counts: dict = {}
    drawer_first_part: dict = {}
    for p in parts:
        did = p.get("drawer_id")
        if did:
            drawer_counts[did] = drawer_counts.get(did, 0) + 1
            pnum = p.get("part_num", "")
            existing_pnum = drawer_first_part.get(did)
            if existing_pnum is None or pnum < existing_pnum:
                drawer_first_part[did] = pnum

    for d in drawers:
        did = d["id"]
        d["part_count"] = drawer_counts.get(did, 0)
        d["first_part_num"] = drawer_first_part.get(did)

    return sorted(
        drawers,
        key=lambda d: (d.get("cabinet", 0), d.get("row", ""), d.get("col", 0)),
    )


def get_drawer_parts(project_id: str, drawer_id: str) -> list[dict]:
    drawer = get_drawer_by_id(drawer_id)
    if not drawer or drawer.get("project_id") != project_id:
        return []
    resp = _parts_table.query(
        IndexName="drawer-index",
        KeyConditionExpression=Key("drawer_id").eq(drawer_id),
    )
    return _to_python(
        sorted(resp.get("Items", []), key=lambda p: p.get("part_name", ""))
    )


# ── Part helpers ──────────────────────────────────────────────────────────────

def get_part(project_id: str, part_num: str) -> Optional[dict]:
    resp = _parts_table.get_item(Key={"project_id": project_id, "part_num": part_num})
    item = resp.get("Item")
    if not item:
        return None
    part = _to_python(item)
    if part.get("drawer_id"):
        drawer = get_drawer_by_id(part["drawer_id"])
        if drawer:
            part["cabinet"] = drawer.get("cabinet")
            part["row"] = drawer.get("row")
            part["col"] = drawer.get("col")
            part["drawer_label"] = drawer.get("label")
    return part


def search_parts(project_id: str, query: str) -> list[dict]:
    q = query.lower()
    all_parts = _to_python(_query_all(
        _parts_table,
        KeyConditionExpression=Key("project_id").eq(project_id),
    ))
    filtered = [
        p for p in all_parts
        if q in p.get("part_num", "").lower()
        or q in p.get("part_name", "").lower()
        or q in (p.get("category") or "").lower()
    ]
    drawers_map = _get_drawers_map(project_id)
    for p in filtered:
        did = p.get("drawer_id")
        if did:
            d = drawers_map.get(did)
            if d:
                p["cabinet"] = d.get("cabinet")
                p["row"] = d.get("row")
                p["col"] = d.get("col")
                p["drawer_label"] = d.get("label")
    return sorted(filtered, key=lambda p: p.get("part_name", ""))


def list_parts(project_id: str) -> list[dict]:
    all_parts = _to_python(_query_all(
        _parts_table,
        KeyConditionExpression=Key("project_id").eq(project_id),
    ))
    drawers_map = _get_drawers_map(project_id)
    for p in all_parts:
        did = p.get("drawer_id")
        if did:
            d = drawers_map.get(did)
            if d:
                p["cabinet"] = d.get("cabinet")
                p["row"] = d.get("row")
                p["col"] = d.get("col")
                p["drawer_label"] = d.get("label")
    return sorted(all_parts, key=lambda p: p.get("part_name", ""))


def upsert_part(project_id: str, part_num: str, part_name: str, category: str = None,
                drawer_id: str = None, notes: str = None,
                ai_description: str = None) -> dict:
    existing = get_part(project_id, part_num)
    item: dict = {
        "project_id": project_id,
        "part_num": part_num,
        "part_name": part_name,
        "created_at": (existing or {}).get("created_at") or datetime.now(timezone.utc).isoformat(),
    }
    if category is not None:
        item["category"] = category
    if drawer_id is not None:
        item["drawer_id"] = drawer_id
    if notes is not None:
        item["notes"] = notes
    if ai_description is not None:
        item["ai_description"] = ai_description
    _parts_table.put_item(Item=item)
    return get_part(project_id, part_num)


def update_part(project_id: str, part_num: str, **kwargs) -> Optional[dict]:
    allowed = {"part_name", "category", "drawer_id", "notes", "ai_description"}
    updates = {k: v for k, v in kwargs.items() if k in allowed}
    if not updates:
        return get_part(project_id, part_num)
    update_exprs = []
    names = {}
    values = {}
    for k, v in updates.items():
        name_ph = f"#f_{k}"
        val_ph = f":v_{k}"
        update_exprs.append(f"{name_ph} = {val_ph}")
        names[name_ph] = k
        values[val_ph] = v
    _parts_table.update_item(
        Key={"project_id": project_id, "part_num": part_num},
        UpdateExpression="SET " + ", ".join(update_exprs),
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
    )
    return get_part(project_id, part_num)


# ── Parts catalog (S3-backed, lazily loaded into memory) ─────────────────────

_catalog: dict = {}
_catalog_loaded: bool = False


def _load_catalog() -> bool:
    global _catalog, _catalog_loaded
    if _catalog_loaded:
        return True
    try:
        resp = _s3.get_object(Bucket=CATALOG_BUCKET, Key="parts.csv.gz")
        content = resp["Body"].read()
        reader = csv.DictReader(
            io.TextIOWrapper(gzip.open(io.BytesIO(content)), encoding="utf-8")
        )
        catalog: dict = {}
        for row in reader:
            catalog[row["part_num"]] = {
                "name": row["name"],
                "part_material": row.get("part_material"),
            }
        _catalog = catalog
        _catalog_loaded = True
        return True
    except Exception:
        return False


def search_catalog(query: str, limit: int = 20) -> list[dict]:
    if not _catalog_loaded:
        _load_catalog()
    q = query.lower()
    results = []
    for part_num, info in _catalog.items():
        name = info["name"].lower()
        if q in name or q in part_num.lower():
            results.append({
                "part_num": part_num,
                "name": info["name"],
                "part_material": info.get("part_material"),
            })
    results.sort(key=lambda r: (0 if r["name"].lower().startswith(q) else 1, len(r["name"])))
    return results[:limit]


def catalog_count() -> int:
    if _catalog_loaded:
        return len(_catalog)
    try:
        resp = _s3.get_object(Bucket=CATALOG_BUCKET, Key="catalog_meta.json")
        meta = json.loads(resp["Body"].read())
        return meta.get("count", 0)
    except Exception:
        return 0


# ── Import / Export ───────────────────────────────────────────────────────────

def export_all(project_id: str) -> dict:
    drawers = _to_python(_query_all(
        _drawers_table,
        IndexName="project-index",
        KeyConditionExpression=Key("project_id").eq(project_id),
    ))
    parts = _to_python(_query_all(
        _parts_table,
        KeyConditionExpression=Key("project_id").eq(project_id),
    ))
    return {
        "drawers": sorted(
            drawers,
            key=lambda d: (d.get("cabinet", 0), d.get("row", ""), d.get("col", 0)),
        ),
        "parts": sorted(parts, key=lambda p: p.get("part_num", "")),
    }


def import_data(project_id: str, data: dict):
    drawer_id_map: dict = {}
    for d in data.get("drawers", []):
        new_drawer = create_drawer(
            project_id, d["cabinet"], d["row"], d["col"],
            label=d.get("label"), notes=d.get("notes"),
        )
        old_id = d.get("id")
        if old_id is not None:
            drawer_id_map[str(old_id)] = new_drawer["id"]

    for p in data.get("parts", []):
        old_drawer_id = p.get("drawer_id")
        new_drawer_id = drawer_id_map.get(str(old_drawer_id), old_drawer_id) if old_drawer_id is not None else None
        upsert_part(
            project_id, p["part_num"], p["part_name"],
            category=p.get("category"),
            drawer_id=new_drawer_id,
            notes=p.get("notes"),
            ai_description=p.get("ai_description"),
        )

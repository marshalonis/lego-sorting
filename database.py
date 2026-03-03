import sqlite3
from contextlib import contextmanager
from typing import Optional

DB_PATH = "lego.db"


def get_connection():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


@contextmanager
def db():
    conn = get_connection()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db():
    with db() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS drawers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                cabinet INTEGER NOT NULL,
                row TEXT NOT NULL,
                col INTEGER NOT NULL,
                label TEXT,
                notes TEXT,
                UNIQUE(cabinet, row, col)
            );

            CREATE TABLE IF NOT EXISTS part_locations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                part_num TEXT NOT NULL UNIQUE,
                part_name TEXT NOT NULL,
                category TEXT,
                drawer_id INTEGER REFERENCES drawers(id),
                notes TEXT,
                ai_description TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        """)


# --- Drawer helpers ---

def create_drawer(conn, cabinet: int, row: str, col: int, label: str = None, notes: str = None) -> dict:
    cur = conn.execute(
        "INSERT OR REPLACE INTO drawers (cabinet, row, col, label, notes) VALUES (?, ?, ?, ?, ?)",
        (cabinet, row.upper(), col, label, notes),
    )
    return get_drawer_by_id(conn, cur.lastrowid)


def get_drawer_by_id(conn, drawer_id: int) -> Optional[dict]:
    row = conn.execute("SELECT * FROM drawers WHERE id = ?", (drawer_id,)).fetchone()
    return dict(row) if row else None


def get_drawer_by_location(conn, cabinet: int, row: str, col: int) -> Optional[dict]:
    row = conn.execute(
        "SELECT * FROM drawers WHERE cabinet = ? AND row = ? AND col = ?",
        (cabinet, row.upper(), col),
    ).fetchone()
    return dict(row) if row else None


def list_drawers(conn) -> list[dict]:
    rows = conn.execute("""
        SELECT d.*, COUNT(p.id) as part_count
        FROM drawers d
        LEFT JOIN part_locations p ON p.drawer_id = d.id
        GROUP BY d.id
        ORDER BY d.cabinet, d.row, d.col
    """).fetchall()
    return [dict(r) for r in rows]


def get_drawer_parts(conn, drawer_id: int) -> list[dict]:
    rows = conn.execute(
        "SELECT * FROM part_locations WHERE drawer_id = ? ORDER BY part_name",
        (drawer_id,),
    ).fetchall()
    return [dict(r) for r in rows]


# --- Part helpers ---

def get_part(conn, part_num: str) -> Optional[dict]:
    row = conn.execute(
        "SELECT p.*, d.cabinet, d.row, d.col, d.label as drawer_label FROM part_locations p LEFT JOIN drawers d ON d.id = p.drawer_id WHERE p.part_num = ?",
        (part_num,),
    ).fetchone()
    return dict(row) if row else None


def search_parts(conn, query: str) -> list[dict]:
    q = f"%{query}%"
    rows = conn.execute(
        """SELECT p.*, d.cabinet, d.row, d.col, d.label as drawer_label
           FROM part_locations p
           LEFT JOIN drawers d ON d.id = p.drawer_id
           WHERE p.part_num LIKE ? OR p.part_name LIKE ? OR p.category LIKE ?
           ORDER BY p.part_name""",
        (q, q, q),
    ).fetchall()
    return [dict(r) for r in rows]


def list_parts(conn) -> list[dict]:
    rows = conn.execute(
        """SELECT p.*, d.cabinet, d.row, d.col, d.label as drawer_label
           FROM part_locations p
           LEFT JOIN drawers d ON d.id = p.drawer_id
           ORDER BY p.part_name"""
    ).fetchall()
    return [dict(r) for r in rows]


def upsert_part(conn, part_num: str, part_name: str, category: str = None,
                drawer_id: int = None, notes: str = None, ai_description: str = None) -> dict:
    existing = get_part(conn, part_num)
    if existing:
        conn.execute(
            """UPDATE part_locations SET part_name=?, category=?, drawer_id=?, notes=?, ai_description=?
               WHERE part_num=?""",
            (part_name, category, drawer_id, notes, ai_description, part_num),
        )
    else:
        conn.execute(
            """INSERT INTO part_locations (part_num, part_name, category, drawer_id, notes, ai_description)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (part_num, part_name, category, drawer_id, notes, ai_description),
        )
    return get_part(conn, part_num)


def update_part(conn, part_num: str, **kwargs) -> Optional[dict]:
    allowed = {"part_name", "category", "drawer_id", "notes", "ai_description"}
    updates = {k: v for k, v in kwargs.items() if k in allowed}
    if not updates:
        return get_part(conn, part_num)
    fields = ", ".join(f"{k}=?" for k in updates)
    values = list(updates.values()) + [part_num]
    conn.execute(f"UPDATE part_locations SET {fields} WHERE part_num=?", values)
    return get_part(conn, part_num)


# --- Import / Export ---

def export_all(conn) -> dict:
    drawers = conn.execute("SELECT * FROM drawers ORDER BY cabinet, row, col").fetchall()
    parts = conn.execute("SELECT * FROM part_locations ORDER BY part_num").fetchall()
    return {
        "drawers": [dict(d) for d in drawers],
        "parts": [dict(p) for p in parts],
    }


def import_data(conn, data: dict):
    for d in data.get("drawers", []):
        conn.execute(
            """INSERT INTO drawers (cabinet, row, col, label, notes)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(cabinet, row, col) DO UPDATE SET
                 label=excluded.label, notes=excluded.notes""",
            (d["cabinet"], d["row"], d["col"], d.get("label"), d.get("notes")),
        )
    for p in data.get("parts", []):
        # Resolve drawer_id by location if needed
        drawer_id = p.get("drawer_id")
        conn.execute(
            """INSERT INTO part_locations (part_num, part_name, category, drawer_id, notes, ai_description)
               VALUES (?, ?, ?, ?, ?, ?)
               ON CONFLICT(part_num) DO UPDATE SET
                 part_name=excluded.part_name,
                 category=excluded.category,
                 drawer_id=excluded.drawer_id,
                 notes=excluded.notes,
                 ai_description=excluded.ai_description""",
            (p["part_num"], p["part_name"], p.get("category"), drawer_id,
             p.get("notes"), p.get("ai_description")),
        )

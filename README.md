# LEGO Sorting Catalog

A mobile-first web app to catalog LEGO bricks into Akro-Mils storage drawers.
Take a photo of a brick → AI identifies it → app shows the drawer location (or lets you assign one).

## Setup

```bash
# Activate the virtual environment
source .venv/bin/activate

# Install dependencies (first time only)
pip install -r requirements.txt
```

## Starting the Server

```bash
AWS_ACCESS_KEY_ID=... \
AWS_SECRET_ACCESS_KEY=... \
AWS_REGION=us-east-1 \
.venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
```

Override the default model (optional):
```bash
BEDROCK_MODEL_ID=us.anthropic.claude-sonnet-4-5-20250929-v1:0
```

## Accessing the App

Open **http://localhost:8000** in a browser.

To use on your phone, connect both devices to the same WiFi and open:
```
http://<your-machine-ip>:8000
```

## First Time Setup

1. Start the server
2. Open the app and go to the **Data tab**
3. Click **Download Parts Catalog** — downloads ~60k parts from Rebrickable into the local DB (one time, ~15 sec). Enables name search on the Identify tab.
4. Click **Import Catalog** if you have a previously exported JSON to restore

## Session Workflow

1. Start the server
2. **Data tab → Import** — upload your last exported JSON to restore the catalog
3. Sort bricks:
   - **Photo**: tap the camera button to photograph a brick → AI identifies it
   - **Name search**: type a part name (e.g. "1x2 plate") to find the part number
   - **Override**: enter a part number manually and click Look Up to verify against Brick Architect
   - Assign unrecognized parts to a drawer
4. **Data tab → Export** — download the updated JSON
5. Stop the server

## Features

- **AI identification** via AWS Bedrock (Claude Haiku) — photo → part name, number, category, confidence
- **Name search** — search 60k+ parts by name using local Rebrickable catalog
- **Brick Architect integration** — part images, label downloads (.lbx), and QR code labels for Brother printers
- **Drawer grid** — color-coded view: red = occupied, green = empty, dashed = inferred empty slot
- **Browse & edit** — search your catalog, move parts between drawers
- **Import / Export** — JSON snapshot for persistence between sessions

## Drawer Location Scheme

Drawers are labeled `Cabinet · Row · Column`, e.g. **1-B3** = Cabinet 1, Row B, Column 3.

The drawer grid automatically infers empty slots — if you have A1–A4 and B3–B4, it will show B1 and B2 as available.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | — | AWS credential |
| `AWS_SECRET_ACCESS_KEY` | — | AWS credential |
| `AWS_REGION` | `us-east-1` | AWS region for Bedrock |
| `BEDROCK_MODEL_ID` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Override default model |

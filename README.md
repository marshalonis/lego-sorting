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

### Option 1 — Anthropic API

```bash
ANTHROPIC_API_KEY=sk-ant-... .venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
```

### Option 2 — AWS Bedrock

```bash
AI_PROVIDER=bedrock \
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

## Session Workflow

1. Start the server
2. **Data tab → Import** — upload your last exported JSON to restore the catalog
3. Sort bricks — photograph each one, assign to drawers
4. **Data tab → Export** — download the updated JSON
5. Stop the server

## Drawer Location Scheme

Drawers are labeled `Cabinet · Row · Column`, e.g. **1-B3** = Cabinet 1, Row B, Column 3.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Required when `AI_PROVIDER=anthropic` |
| `AI_PROVIDER` | `anthropic` | `anthropic` or `bedrock` |
| `AWS_ACCESS_KEY_ID` | — | Required for Bedrock |
| `AWS_SECRET_ACCESS_KEY` | — | Required for Bedrock |
| `AWS_REGION` | `us-east-1` | AWS region for Bedrock |
| `BEDROCK_MODEL_ID` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Override default Bedrock model |

# LEGO Sorting Catalog

A mobile-first web app to catalog LEGO bricks into storage drawers.
Take a photo of a brick → AI identifies it → app shows the drawer location (or lets you assign one).

Live at **https://bootiak.org**

## Architecture

Fully serverless on AWS:

| Component | Service |
|---|---|
| Frontend | S3 + CloudFront |
| API | Lambda (FastAPI + Mangum) behind API Gateway HTTP API |
| Database | DynamoDB (drawers + parts tables) |
| Image storage | S3 (1-day lifecycle, presigned upload URLs) |
| Parts catalog | S3 (Rebrickable CSV, ~60k parts) |
| AI identification | AWS Bedrock (Claude Haiku) |
| Auth | Cognito User Pool (invite-only, JWT) |
| Custom domain | CloudFront + ACM certificate |

## Deploying

### Prerequisites

- AWS CDK v2: `npm install -g aws-cdk`
- [Finch](https://github.com/runfinch/finch) (or Docker) for Lambda bundling
- Python virtualenv for CDK dependencies
- An ACM certificate in `us-east-1` for your domain

### First deploy

```bash
cd serverless/cdk

# Create and activate virtualenv
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Update constants at top of stacks/lego_stack.py
# DOMAIN_NAME = "your-domain.com"
# CERTIFICATE_ARN = "arn:aws:acm:us-east-1:..."

# Deploy (replace profile/account as needed)
CDK_DOCKER=finch \
AWS_PROFILE=ChildAdmin \
CDK_DEFAULT_ACCOUNT=535002893187 \
PATH=".venv/bin:/opt/homebrew/bin:$PATH" \
cdk deploy
```

### After deploy

1. **Create a Cognito user** — go to the Cognito User Pool in the AWS Console (the User Pool ID is in the CDK outputs), create a user with a temporary password. The user will be prompted to set a new password on first login.

2. **Load the parts catalog** — invoke the catalog loader Lambda once:
   ```bash
   aws lambda invoke --function-name <CatalogLoaderFunctionName from outputs> \
     --profile ChildAdmin /dev/stdout
   ```
   This downloads ~60k parts from Rebrickable into S3 (~15 seconds).

3. **DNS** — point your domain to the CloudFront distribution. If using Route 53 at the zone apex, create an **A record (ALIAS)** pointing to the CloudFront domain (hosted zone ID `Z2FDTNDATAQYW2`). CNAMEs are not allowed at the apex.

## Features

- **AI identification** — photograph a brick, Claude Haiku identifies part name, number, category, and confidence score
- **Name search** — search 60k+ parts by name using the Rebrickable catalog
- **Brick Architect integration** — part images, label downloads (`.lbx`) and QR code labels for Brother P-touch printers
- **STL print link** — "Find STL (3D Print)" button searches Printables.com for 3D-printable models of the identified part, for printing storage labels or reference models
- **Drawer grid** — visual cabinet layout showing occupied/empty drawers with part thumbnails
- **Browse & edit** — search your catalog, move parts between drawers
- **Import / Export** — JSON snapshot for backup and restore

## Drawer Location Scheme

Drawers are labeled `Cabinet · Row · Column`, e.g. **1-B3** = Cabinet 1, Row B, Column 3.

The drawer grid automatically infers empty slots between existing drawers.

## Project Structure

```
serverless/
├── cdk/                  # CDK infrastructure (Python)
│   ├── app.py
│   ├── cdk.json
│   └── stacks/
│       └── lego_stack.py
├── lambda/
│   ├── api/              # Main FastAPI Lambda
│   │   ├── handler.py
│   │   ├── database.py
│   │   ├── ai_identify.py
│   │   └── requirements.txt
│   └── catalog_loader/   # One-time Rebrickable catalog loader
│       └── handler.py
└── frontend/             # Static SPA (HTML + CSS + JS)
    ├── index.html
    ├── app.js
    └── style.css
```

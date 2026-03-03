"""
Catalog Loader Lambda

Downloads the Rebrickable parts catalog CSV and stores it in S3.
Invoked once manually (or via console) after first deployment.

Usage:
    aws lambda invoke --function-name <CatalogLoaderFunctionName> /dev/stdout
"""
import csv
import gzip
import io
import json
import os
import urllib.request

import boto3

CATALOG_BUCKET = os.environ.get("CATALOG_BUCKET", "")
REBRICKABLE_URL = "https://cdn.rebrickable.com/media/downloads/parts.csv.gz"

s3 = boto3.client("s3")


def handler(event, context):
    print(f"Downloading Rebrickable catalog from {REBRICKABLE_URL}")

    with urllib.request.urlopen(REBRICKABLE_URL, timeout=240) as response:
        raw_gz = response.read()

    # Count rows
    reader = csv.DictReader(
        io.TextIOWrapper(gzip.open(io.BytesIO(raw_gz)), encoding="utf-8")
    )
    count = sum(1 for _ in reader)
    print(f"Parsed {count} parts")

    # Upload gzipped CSV to S3
    s3.put_object(
        Bucket=CATALOG_BUCKET,
        Key="parts.csv.gz",
        Body=raw_gz,
        ContentType="application/gzip",
    )

    # Write count metadata so the API can report status without loading the full CSV
    s3.put_object(
        Bucket=CATALOG_BUCKET,
        Key="catalog_meta.json",
        Body=json.dumps({"count": count}).encode(),
        ContentType="application/json",
    )

    print(f"Uploaded to s3://{CATALOG_BUCKET}/parts.csv.gz ({count} parts)")
    return {"status": "ok", "parts_loaded": count}

#!/usr/bin/env python3
"""Generate a read-only SAS token for collaborator access to CivBench data."""

import argparse
from datetime import datetime, timedelta, timezone
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=90, help="Validity (default: 90)")
    parser.add_argument("--out", default="civbench_sas_token.txt", help="Output file")
    args = parser.parse_args()

    from azure.storage.blob import (
        ContainerSasPermissions,
        generate_container_sas,
    )

    # Load account key from evals/.env
    env_file = Path(__file__).resolve().parent.parent / "evals" / ".env"
    env = {}
    for line in env_file.read_text().splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()

    account = env.get("AZURE_STORAGE_ACCOUNT_NAME", "civbenchstorage")
    key = env["AZURE_STORAGE_ACCOUNT_KEY"]

    expiry = datetime.now(timezone.utc) + timedelta(days=args.days)
    sas = generate_container_sas(
        account_name=account,
        container_name="telemetry",
        account_key=key,
        permission=ContainerSasPermissions(read=True, list=True),
        expiry=expiry,
    )

    Path(args.out).write_text(f"AZURE_SAS_TOKEN={sas}\n")
    print(f"SAS token written to {args.out} (expires {expiry:%Y-%m-%d})")


if __name__ == "__main__":
    main()

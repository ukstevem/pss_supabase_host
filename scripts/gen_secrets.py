#!/usr/bin/env python3
"""Generate Supabase self-hosted secrets, output as .env-formatted lines.

Stdlib-only — no PyJWT or other deps required. Builds the HS256 JWTs from scratch.

Usage
-----
    python3 gen_secrets.py > /opt/pss-supabase-host/.env

    # Rotate non-JWT secrets only, keeping the existing JWT_SECRET (so already-issued
    # ANON_KEY / SERVICE_ROLE_KEY remain valid):
    python3 gen_secrets.py --jwt-secret "$(grep ^JWT_SECRET= existing.env | cut -d= -f2)" > new.env

    # Custom dashboard username:
    python3 gen_secrets.py --dashboard-username admin > .env

Outputs (stdout) the following KEY=value lines:
    JWT_SECRET, ANON_KEY, SERVICE_ROLE_KEY,
    POSTGRES_PASSWORD, DASHBOARD_USERNAME, DASHBOARD_PASSWORD
"""
import argparse
import base64
import hashlib
import hmac
import json
import secrets
import time


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_jwt(role: str, secret: str, exp_years: int = 10) -> str:
    """Build an HS256 JWT for a given Supabase role (`anon` or `service_role`)."""
    header = b64url(
        json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode()
    )
    iat = int(time.time())
    exp = iat + exp_years * 365 * 24 * 3600
    payload = b64url(
        json.dumps(
            {"role": role, "iss": "supabase", "iat": iat, "exp": exp},
            separators=(",", ":"),
        ).encode()
    )
    msg = f"{header}.{payload}".encode()
    sig = b64url(hmac.new(secret.encode(), msg, hashlib.sha256).digest())
    return f"{header}.{payload}.{sig}"


def random_str(n: int) -> str:
    """URL-safe random alphanumeric string of length n."""
    alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    return "".join(secrets.choice(alphabet) for _ in range(n))


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument(
        "--jwt-secret",
        help="Reuse an existing JWT secret (rotates other secrets only)",
    )
    p.add_argument("--dashboard-username", default="supabase")
    args = p.parse_args()

    jwt_secret = args.jwt_secret or random_str(64)
    print(f"JWT_SECRET={jwt_secret}")
    print(f"ANON_KEY={make_jwt('anon', jwt_secret)}")
    print(f"SERVICE_ROLE_KEY={make_jwt('service_role', jwt_secret)}")
    print(f"POSTGRES_PASSWORD={random_str(32)}")
    print(f"DASHBOARD_USERNAME={args.dashboard_username}")
    print(f"DASHBOARD_PASSWORD={random_str(24)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

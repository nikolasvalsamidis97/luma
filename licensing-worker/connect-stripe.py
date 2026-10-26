#!/usr/bin/env python3
"""Connect a configured Worker to Stripe without putting secrets in chat or files."""
import argparse
import getpass
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent
EVENTS = ["checkout.session.completed", "checkout.session.async_payment_succeeded",
          "customer.subscription.created", "customer.subscription.updated",
          "customer.subscription.deleted", "invoice.paid", "invoice.payment_failed"]
VERSION = "2025-02-24.acacia"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="wrangler.jsonc")
    args = parser.parse_args()
    config_path = (ROOT / args.config).resolve()
    config = json.loads(config_path.read_text())
    settings = config["vars"]
    mode = settings["BILLING_MODE"]
    if mode not in ("test", "live"):
        raise ValueError("Choose an explicit test or live billing mode.")
    base = settings["LUMA_PUBLIC_URL"].rstrip("/")
    parsed = urllib.parse.urlsplit(base)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.query or parsed.fragment:
        raise ValueError("Configure the deployed HTTPS Worker URL first.")
    expected = json.loads((ROOT.parent / "licensing-server/stripe-test-config.json").read_text())
    expected_account = expected["sandbox_account_id" if mode == "test" else "live_account_id"]
    print(f"Connect Stripe {mode.upper()} to {config['name']} at {base}")
    print("The key will be entered invisibly and stored only in Cloudflare's encrypted secrets.")
    print("This verifies the €4/month plan and configures its payment-event webhook. No customer is charged.")
    key = getpass.getpass(f"Paste Stripe {mode} secret key, then press Return: ").strip()
    if not re.fullmatch(rf"(?:sk|rk)_{mode}_[A-Za-z0-9]+", key):
        raise ValueError(f"Expected a {mode} secret/restricted key. Nothing was uploaded.")
    context = ssl.create_default_context(cafile="/etc/ssl/cert.pem" if sys.platform == "darwin" else None)

    def stripe(path, fields=None):
        headers = {"Authorization": "Bearer " + key, "Stripe-Version": VERSION,
                   "User-Agent": "Luma-Setup/0.8"}
        body = None
        if fields is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            body = urllib.parse.urlencode(fields).encode()
        request = urllib.request.Request("https://api.stripe.com/v1/" + path, body, headers)
        try:
            with urllib.request.urlopen(request, context=context, timeout=25) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            # Do not print response bodies, request headers or credentials.
            raise RuntimeError(f"Stripe returned HTTP {error.code} for {path.split('?')[0]}. Check key permissions and account mode.") from None

    account = stripe("account")
    if account.get("id") != expected_account:
        raise ValueError("This key belongs to a different Stripe account. Nothing was uploaded.")
    if mode == "live" and not account.get("charges_enabled"):
        raise ValueError("Stripe has not enabled live charges for this account. Complete its account requirements first.")
    price = stripe("prices/" + settings["STRIPE_PRICE_ID"])
    if not (price.get("active") and price.get("livemode") == (mode == "live") and
            price.get("currency") == "eur" and price.get("unit_amount") == 400 and
            price.get("recurring", {}).get("interval") == "month" and
            price.get("recurring", {}).get("interval_count") == 1):
        raise ValueError("The configured price must be active, EUR 4 per month, in the matching mode.")
    portal = stripe("billing_portal/configurations/" + settings["STRIPE_PORTAL_CONFIGURATION"])
    features = portal.get("features", {})
    if not (portal.get("active") and features.get("subscription_cancel", {}).get("enabled") and
            features.get("payment_method_update", {}).get("enabled")):
        raise ValueError("The customer portal must allow cancellation and payment-method updates.")
    endpoint_url = base + "/v1/stripe/webhook"
    endpoints = stripe("webhook_endpoints?limit=100")
    if endpoints.get("has_more"):
        raise ValueError("Too many webhook endpoints to verify automatically; review the account first.")
    matches = [e for e in endpoints["data"] if e.get("url") == endpoint_url]
    if len(matches) > 1:
        raise ValueError("Multiple matching webhook destinations exist; review them before connecting.")
    if matches:
        endpoint = matches[0]
        if endpoint.get("status") != "enabled" or endpoint.get("api_version") != VERSION or not set(EVENTS).issubset(endpoint.get("enabled_events", [])):
            raise ValueError("The existing webhook destination has different settings; review it first.")
        signing_secret = getpass.getpass("Paste this endpoint's signing secret (whsec_), then press Return: ").strip()
    else:
        fields = {"url": endpoint_url, "api_version": VERSION,
                  "description": f"Luma {mode} licensing subscription events"}
        fields.update({f"enabled_events[{i}]": event for i, event in enumerate(EVENTS)})
        endpoint = stripe("webhook_endpoints", fields)
        signing_secret = endpoint["secret"]
    if not re.fullmatch(r"whsec_[A-Za-z0-9]+", signing_secret):
        raise ValueError("Invalid webhook signing secret. Nothing was uploaded.")
    env = os.environ.copy()
    local_node = ROOT.parent / ".tools/node-v24.22.1-darwin-arm64/bin"
    if local_node.exists():
        env["PATH"] = str(local_node) + os.pathsep + env.get("PATH", "")
    result = subprocess.run([str(ROOT / "node_modules/.bin/wrangler"), "secret", "bulk",
                             "--config", str(config_path)],
                            input=json.dumps({"STRIPE_SECRET_KEY": key, "STRIPE_WEBHOOK_SECRET": signing_secret}),
                            text=True, capture_output=True, cwd=ROOT, env=env)
    if result.returncode:
        raise RuntimeError("Cloudflare secret upload failed. The Stripe webhook exists; retry using its signing secret from Stripe.")
    receipt = {"mode": mode, "worker": config["name"], "url": base,
               "account": account["id"], "webhook": endpoint["id"],
               "price": price["id"], "portal": portal["id"], "connected": True}
    private = ROOT / "private"
    private.mkdir(mode=0o700, exist_ok=True)
    fd = os.open(private / f"stripe-{mode}-connection.json", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(receipt, output, indent=2)
    print("Connected. Stripe keys are stored in Cloudflare; no key was saved in this folder.")
    print("Checkout and webhook testing must finish before releasing the paid app.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, KeyError, OSError, EOFError) as error:
        print("Setup stopped: " + str(error), file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
# edge/admin_key_init.py
# Stage 5-3b helper: store SHA-256(admin key) in Vault KV edge-ai-demo-kv/edge-device/admin-key
# with the EDGE token, create-only (cas=0).  Run as user edge-ingest by scripts/21-vault-widgets.sh.
# The argument is a hash, not a secret; the admin key itself never reaches this process.
#
# stdout (one word): CREATED | EXISTS_SAME | EXISTS_DIFFERENT
# exit code: 0 for the three outcomes above, 1 for any error (message on stderr).

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import requests  # noqa: E402
import trusted_edge as te  # noqa: E402


def main() -> int:
    if len(sys.argv) != 2 or len(sys.argv[1]) != 64:
        print("usage: admin_key_init.py <sha256-hex>", file=sys.stderr)
        return 1
    want = sys.argv[1].lower()
    try:
        have = te.load_key_hash(te.ADMIN_KV_PATH)
    except requests.HTTPError as exc:
        if exc.response is None or exc.response.status_code != 404:
            print(f"read of {te.ADMIN_KV_PATH} failed: HTTP "
                  f"{exc.response.status_code if exc.response is not None else '?'}", file=sys.stderr)
            return 1
        have = None
    except RuntimeError:
        print(f"{te.ADMIN_KV_PATH} exists but holds no valid sha256 field", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"read of {te.ADMIN_KV_PATH} failed: {type(exc).__name__}", file=sys.stderr)
        return 1

    if have is not None:
        print("EXISTS_SAME" if have == want else "EXISTS_DIFFERENT")
        return 0

    try:
        te._vault_post(te.ADMIN_KV_PATH, token=te._vault_token(),
                       body={"options": {"cas": 0}, "data": {"sha256": want}})
    except requests.HTTPError as exc:
        print(f"create of {te.ADMIN_KV_PATH} failed: HTTP "
              f"{exc.response.status_code if exc.response is not None else '?'}", file=sys.stderr)
        return 1
    print("CREATED")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Select a valid Apple Development identity without silently changing signers."""
import os
import re
import sys


def select_identity(listing, requested="", installed=""):
    identities = re.findall(r'\b([0-9A-Fa-f]{40})\s+"(Apple Development: [^"\n]+)"', listing)
    identities = list(dict.fromkeys(identities))
    if requested:
        matches = [item for item in identities if requested == item[1] or requested.upper() == item[0].upper()]
    elif installed.startswith("Apple Development: "):
        matches = [item for item in identities if item[1] == installed]
    else:
        matches = identities
    if len(matches) != 1:
        raise ValueError("开发版需要唯一且有效的 Apple Development 签名身份。请解锁原签名钥匙串；有多个证书时，通过 VORSSAINT_DEV_SIGNING_IDENTITY 指定证书 SHA-1。不会回退到自签名或临时签名。")
    return matches[0][0].upper()


if __name__ == "__main__":
    try:
        print(select_identity(sys.stdin.read(), os.environ.get("VORSSAINT_DEV_SIGNING_IDENTITY", ""), sys.argv[1] if len(sys.argv) > 1 else ""))
    except ValueError as error:
        print(f"✗ {error}", file=sys.stderr)
        sys.exit(1)

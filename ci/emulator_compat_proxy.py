#!/usr/bin/env python3
"""HTTPS proxy in front of AWS Emulator for CI and local no-auth runs.

This does not fake resource creation. It only rewrites two request shapes
so they match what the emulator (and, for the security-group case, AWS)
accepts:

1. RDS DescribeGlobalClusters with Filters Name=db-cluster-id.
   Current official AWS docs say the only supported filter is "region":
   https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_DescribeGlobalClusters.html
   The Terraform AWS provider (5.100 and 6.73) still sends db-cluster-id
   from findGlobalClusterByDBClusterARN on every provisioned cluster read.
   The emulator follows the documented API and returns 400. This proxy
   strips that filter and forwards the request; the provider still does
   client-side ARN matching, and an empty list is treated as NotFound.

2. EC2 RevokeSecurityGroupEgress for IpProtocol=-1 with FromPort/ToPort 0.
   AWS matches all-protocol rules regardless of the ports in the request.
   The emulator stores the default egress rule with no ports and compares
   them exactly, so Terraform's default-egress revoke fails
   (https://github.com/aws/aws-emulator/issues/46). This proxy drops
   FromPort/ToPort on those members.

Intended for --auth off (CI). Rewriting the body would invalidate SigV4.
"""

from __future__ import annotations

import argparse
import http.server
import re
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from typing import List, Tuple

Pairs = List[Tuple[str, str]]

FILTER_NAME_RE = re.compile(
    r"^(Filters(?:\.member|\.Filter)?)\.(\d+)\.Name$", re.IGNORECASE
)
FILTER_MEMBER_RE = re.compile(
    r"^(Filters(?:\.member|\.Filter)?)\.(\d+)\.", re.IGNORECASE
)
PERM_PROTO_RE = re.compile(
    r"^(IpPermissions(?:\.member)?)\.(\d+)\.IpProtocol$", re.IGNORECASE
)
PERM_PORT_RE = re.compile(
    r"^(IpPermissions(?:\.member)?)\.(\d+)\.(FromPort|ToPort)$", re.IGNORECASE
)


def _action(pairs: Pairs) -> str | None:
    for key, value in pairs:
        if key.lower() == "action":
            return value
    return None


def rewrite_describe_global_clusters(pairs: Pairs) -> tuple[Pairs, bool]:
    drop_indexes: dict[str, set[str]] = {}
    for key, value in pairs:
        match = FILTER_NAME_RE.match(key)
        if match and value == "db-cluster-id":
            drop_indexes.setdefault(match.group(1).lower(), set()).add(match.group(2))
    if not drop_indexes:
        return pairs, False

    def drop(key: str) -> bool:
        match = FILTER_MEMBER_RE.match(key)
        return bool(
            match
            and match.group(2) in drop_indexes.get(match.group(1).lower(), set())
        )

    return [(key, value) for key, value in pairs if not drop(key)], True


def rewrite_revoke_egress(pairs: Pairs) -> tuple[Pairs, bool]:
    all_proto: dict[str, set[str]] = {}
    for key, value in pairs:
        match = PERM_PROTO_RE.match(key)
        if match and value in ("-1", "all"):
            all_proto.setdefault(match.group(1).lower(), set()).add(match.group(2))
    if not all_proto:
        return pairs, False

    changed = False
    out: Pairs = []
    for key, value in pairs:
        match = PERM_PORT_RE.match(key)
        if match and match.group(2) in all_proto.get(match.group(1).lower(), set()):
            changed = True
            continue
        out.append((key, value))
    return out, changed


def rewrite_pairs(pairs: Pairs) -> tuple[Pairs, str | None]:
    action = _action(pairs)
    if action == "DescribeGlobalClusters":
        pairs, changed = rewrite_describe_global_clusters(pairs)
        return pairs, "DescribeGlobalClusters:strip-db-cluster-id" if changed else None
    if action == "RevokeSecurityGroupEgress":
        pairs, changed = rewrite_revoke_egress(pairs)
        return pairs, "RevokeSecurityGroupEgress:drop-ports-on-protocol--1" if changed else None
    return pairs, None


def rewrite_body(content_type: str, body: bytes) -> tuple[bytes, str | None]:
    if not body:
        return body, None
    ctype = (content_type or "").split(";")[0].strip().lower()
    if ctype not in (
        "",
        "application/x-www-form-urlencoded",
        "application/x-www-form-urlencoded; charset=utf-8",
    ) and ctype not in (
        "application/x-www-form-urlencoded",
    ):
        # Still try if it looks like a query string (AWS Query protocol).
        if b"Action=" not in body and b"action=" not in body:
            return body, None
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        return body, None
    pairs = urllib.parse.parse_qsl(text, keep_blank_values=True)
    if not pairs:
        return body, None
    new_pairs, reason = rewrite_pairs(pairs)
    if not reason:
        return body, None
    return urllib.parse.urlencode(new_pairs).encode("utf-8"), reason


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream: str = ""
    insecure_ssl: ssl.SSLContext | None = None

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.log_date_time_string(), fmt % args))

    def _forward(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        content_type = self.headers.get("Content-Type", "")
        body, reason = rewrite_body(content_type, body)
        if reason:
            self.log_message("rewrote %s %s", self.command, reason)

        upstream = self.upstream.rstrip("/") + self.path
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower()
            not in {
                "host",
                "content-length",
                "transfer-encoding",
                "connection",
                "keep-alive",
                "proxy-connection",
            }
        }
        if body:
            headers["Content-Length"] = str(len(body))
        request = urllib.request.Request(
            upstream, data=body if self.command != "GET" else None, method=self.command, headers=headers
        )
        try:
            with urllib.request.urlopen(request, context=self.insecure_ssl, timeout=120) as resp:
                payload = resp.read()
                self.send_response(resp.status)
                for key, value in resp.headers.items():
                    if key.lower() in {"transfer-encoding", "connection", "keep-alive"}:
                        continue
                    if key.lower() == "content-length":
                        continue
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
        except urllib.error.HTTPError as err:
            payload = err.read()
            self.send_response(err.code)
            for key, value in err.headers.items():
                if key.lower() in {"transfer-encoding", "connection", "keep-alive", "content-length"}:
                    continue
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            if reason:
                self.log_message("upstream %s after rewrite %s: %s", err.code, reason, payload[:200])

    def do_GET(self) -> None:  # noqa: N802
        self._forward()

    def do_POST(self) -> None:  # noqa: N802
        self._forward()

    def do_PUT(self) -> None:  # noqa: N802
        self._forward()

    def do_HEAD(self) -> None:  # noqa: N802
        self._forward()

    def do_DELETE(self) -> None:  # noqa: N802
        self._forward()


def make_self_signed_cert(directory: str) -> tuple[str, str]:
    cert = f"{directory}/cert.pem"
    key = f"{directory}/key.pem"
    subprocess.check_call(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-keyout",
            key,
            "-out",
            cert,
            "-days",
            "1",
            "-nodes",
            "-subj",
            "/CN=127.0.0.1",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return cert, key


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", default="127.0.0.1:9298", help="host:port to listen on")
    parser.add_argument("--upstream", default="https://127.0.0.1:9297", help="emulator base URL")
    args = parser.parse_args()
    host, port_s = args.listen.rsplit(":", 1)
    port = int(port_s)

    tmp = tempfile.TemporaryDirectory(prefix="emulator-compat-proxy-")
    cert, key = make_self_signed_cert(tmp.name)

    insecure = ssl._create_unverified_context()
    ProxyHandler.upstream = args.upstream
    ProxyHandler.insecure_ssl = insecure

    server = http.server.ThreadingHTTPServer((host, port), ProxyHandler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=cert, keyfile=key)
    server.socket = context.wrap_socket(server.socket, server_side=True)

    print(f"emulator compatibility proxy listening on https://{host}:{port} -> {args.upstream}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        tmp.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

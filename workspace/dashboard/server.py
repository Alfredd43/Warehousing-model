"""PetHaven dashboard: local HTTP server for the static app and its JSON API.

A small standard-library server for the localhost lab prototype (not
production hosting). It serves workspace/dashboard/static and the /api
routes, opening one database connection per request.

Usage
    Inside the lab (see docs/dashboard_runbook.md):
        docker compose -f docker-compose.yml -f workspace/dashboard/compose.dashboard.yml up -d dashboard
    then open http://localhost:8080

    Directly:
        python workspace/dashboard/server.py [--host 127.0.0.1] [--port 8080] [--database pethaven_demo]

The database is never built or rebuilt here; run scripts/build.py first.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import sys
import traceback
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "scripts"))

import psycopg2  # noqa: E402
import psycopg2.errors  # noqa: E402

import actions  # noqa: E402
import pethaven_db as db  # noqa: E402
import queries  # noqa: E402
import serialization as ser  # noqa: E402

STATIC = HERE / "static"
MAX_BODY = 64 * 1024
LOCAL_HOSTS = {"localhost", "127.0.0.1", "[::1]"}

DATABASE = os.environ.get("DASHBOARD_DB", db.DEMO_DATABASE)

# --- routes -----------------------------------------------------------------------
GET_ROUTES = [
    (r"/api/health", queries.health),
    (r"/api/status", queries.status),
    (r"/api/overview", queries.overview),
    (r"/api/catalogue", queries.catalogue),
    (r"/api/website-stock", queries.website_stock),
    (r"/api/sync/latest", queries.sync_latest),
    (r"/api/stock", queries.stock),
    (r"/api/stock/events", queries.stock_events),
    (r"/api/sales", queries.sales),
    (r"/api/checkout/blocked", queries.checkout_blocked),
    (r"/api/checkout/attempts/(\d+)", queries.checkout_attempt),
    (r"/api/reservations", queries.reservations),
    (r"/api/integration/mappings", queries.mappings),
    (r"/api/integration/staging", queries.staging),
    (r"/api/integration/sync-staging", queries.sync_staging),
    (r"/api/integration/runs", queries.runs),
    (r"/api/integration/quality", queries.quality),
    (r"/api/integration/trace", queries.trace),
    (r"/api/demo/baskets/(\d+)", lambda conn, p, bid: queries.Result(actions.basket_view(conn, int(bid)))),
    (r"/api/demo/baskets/(\d+)/pickup-options",
     lambda conn, p, bid: queries.Result({"options": actions.pickup_options(conn, int(bid))})),
    (r"/api/demo/scenarios/sell-out",
     lambda conn, p: queries.Result(actions.sellout_preview(conn, queries.text_param(p, "product")))),
]

POST_ROUTES = [
    (r"/api/demo/sales", actions.record_sale),
    (r"/api/demo/supplier-deliveries", actions.record_supplier_delivery),
    (r"/api/demo/baskets", actions.create_basket),
    (r"/api/demo/baskets/(\d+)/items", actions.set_basket_item),
    (r"/api/demo/baskets/(\d+)/remove-item", actions.remove_basket_item),
    (r"/api/demo/baskets/(\d+)/checkout", actions.checkout),
    (r"/api/demo/sync", actions.sync),
    (r"/api/demo/items/add", actions.add_item),
    (r"/api/demo/etl", actions.run_etl),
    (r"/api/demo/orders/(\d+)/(dispatch|receive|collect|cancel)", actions.order_step),
    (r"/api/demo/cancel-overdue", actions.cancel_overdue),
    (r"/api/demo/scenarios/sell-out", actions.sellout),
]


def match(routes, path):
    for pattern, fn in routes:
        m = re.fullmatch(pattern, path)
        if m:
            return fn, m.groups()
    return None, ()


def connect():
    conn = db.connect(DATABASE)
    return conn


def now_sydney(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT now()")
        return cur.fetchone()[0]


class Handler(BaseHTTPRequestHandler):
    server_version = "PetHavenDashboard/1.0"
    protocol_version = "HTTP/1.1"

    # --- responses ---------------------------------------------------------
    def send_json(self, status: int, payload) -> None:
        body = ser.dumps(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status: int, code: str, message: str, detail=None) -> None:
        self.send_json(status, ser.error(status, code, message, detail=detail))

    def log_message(self, fmt, *args):  # concise access log on stderr
        sys.stderr.write(f"[dashboard] {self.address_string()} {fmt % args}\n")

    # --- GET -----------------------------------------------------------------
    def do_GET(self):
        url = urlsplit(self.path)
        if url.path.startswith("/api/"):
            self.handle_api(GET_ROUTES, url, write=False)
        else:
            self.serve_static(url.path)

    def do_POST(self):
        url = urlsplit(self.path)
        if not url.path.startswith("/api/demo/"):
            return self.send_error_json(404, "not_found", "No such endpoint")
        problem = self.check_write_request()
        if problem:
            return self.send_error_json(403 if problem[0] == "origin" else 415, problem[0], problem[1])
        self.handle_api(POST_ROUTES, url, write=True)

    def do_PUT(self):
        self.send_error_json(405, "method_not_allowed", "Use GET or POST")

    do_DELETE = do_PATCH = do_PUT

    def check_write_request(self):
        host = (self.headers.get("Host") or "").lower()
        hostname = host.rsplit(":", 1)[0] if not host.startswith("[") else host.split("]")[0] + "]"
        if hostname not in LOCAL_HOSTS:
            return ("origin", "Write requests are accepted only from this computer (localhost)")
        origin = self.headers.get("Origin")
        if origin and urlsplit(origin).netloc.lower() != host:
            return ("origin", "Cross-origin write requests are not accepted")
        if (self.headers.get("Content-Type") or "").split(";")[0].strip() != "application/json":
            return ("content_type", "Send the request body as application/json")
        return None

    def read_body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            raise queries.BadRequest("Request body is too large")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise queries.BadRequest("Request body is not valid JSON")
        if not isinstance(body, dict):
            raise queries.BadRequest("Request body must be a JSON object")
        return body

    # --- API -------------------------------------------------------------------
    def handle_api(self, routes, url, write: bool):
        fn, groups = match(routes, url.path)
        if fn is None:
            return self.send_error_json(404, "not_found", "No such endpoint")
        params = parse_qs(url.query)
        try:
            body = self.read_body() if write else None
        except queries.BadRequest as exc:
            return self.send_error_json(422, "invalid_request", str(exc))

        try:
            conn = connect()
        except psycopg2.OperationalError:
            return self.send_error_json(
                503, "database_unavailable",
                f"Cannot reach the database '{DATABASE}'. Start the lab (docker compose up -d) and "
                "build it with scripts/build.py, then retry.")
        try:
            if not write:
                # One consistent snapshot for the several queries of a response.
                conn.set_session(readonly=True, isolation_level="REPEATABLE READ")
            try:
                if write:
                    data = fn(conn, *groups, body) if groups else fn(conn, body)
                    payload = ser.envelope(data, read_at=now_sydney(conn), database=DATABASE,
                                           provenance=["business function in the source system"])
                else:
                    result = fn(conn, params, *groups)
                    payload = ser.envelope(result.data, read_at=now_sydney(conn), database=DATABASE,
                                           scope=result.scope, provenance=result.provenance,
                                           warnings=result.warnings)
                conn.rollback()  # end the read transaction; writes were committed by the action
            except queries.BadRequest as exc:
                conn.rollback()
                return self.send_error_json(422 if write else 400, "invalid_request", str(exc))
            except queries.NotFound as exc:
                conn.rollback()
                return self.send_error_json(404, "not_found", str(exc))
            except actions.Refused as exc:
                conn.rollback()
                return self.send_error_json(409, "refused", str(exc), exc.detail)
            except psycopg2.errors.RaiseException as exc:
                # A business rule in the source system refused the operation.
                conn.rollback()
                return self.send_error_json(409, "refused", exc.diag.message_primary or str(exc))
            except (psycopg2.IntegrityError, psycopg2.DataError) as exc:
                conn.rollback()
                return self.send_error_json(422, "invalid_data", exc.diag.message_primary or "Invalid data")
            except psycopg2.OperationalError:
                return self.send_error_json(503, "database_unavailable",
                                            "The database connection was lost. Retry when it is available.")
            except Exception:
                conn.rollback()
                eid = ser.error_id()
                sys.stderr.write(f"[dashboard] error {eid} on {self.command} {url.path}\n")
                traceback.print_exc()
                return self.send_error_json(500, "server_error",
                                            f"Unexpected server error (reference {eid}).")
        finally:
            conn.close()
        self.send_json(200, payload)

    # --- static files ------------------------------------------------------------
    def serve_static(self, path: str):
        if path in ("", "/"):
            path = "/index.html"
        target = (STATIC / path.lstrip("/")).resolve()
        if STATIC not in target.parents or not target.is_file():
            return self.send_error_json(404, "not_found", "Not found")
        body = target.read_bytes()
        ctype = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        if target.suffix == ".js":
            ctype = "text/javascript"
        self.send_response(200)
        self.send_header("Content-Type", f"{ctype}; charset=utf-8" if ctype.startswith("text/") else ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)


def make_server(host: str, port: int, database: str | None = None) -> ThreadingHTTPServer:
    global DATABASE
    if database:
        DATABASE = database
    if DATABASE not in db.MANAGED_DATABASES:
        raise SystemExit(f"Database must be one of {sorted(db.MANAGED_DATABASES)}")
    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    return server


def main() -> int:
    parser = argparse.ArgumentParser(description="PetHaven dashboard server (localhost prototype)")
    parser.add_argument("--host", default=os.environ.get("DASHBOARD_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("DASHBOARD_PORT", "8080")))
    parser.add_argument("--database", default=None, help="pethaven_demo (default) or pethaven_check")
    args = parser.parse_args()
    server = make_server(args.host, args.port, args.database)
    print(f"PetHaven dashboard on http://{args.host}:{args.port}  (database {DATABASE})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

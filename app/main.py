import asyncio
import logging
import os
import time
from typing import Callable

from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest


logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s service=reservation-api message=%(message)s",
)
logger = logging.getLogger("reservation-api")

app = FastAPI(title="Seazone Reservation API", version=os.getenv("APP_VERSION", "1.7.0"))

REQUEST_COUNT = Counter(
    "reservation_api_http_requests_total",
    "Total HTTP requests served by the reservation API.",
    ["method", "path", "status"],
)
REQUEST_LATENCY = Histogram(
    "reservation_api_http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["method", "path"],
)


def _route_path(request: Request) -> str:
    route = request.scope.get("route")
    return getattr(route, "path", "__unmatched__")


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        logger.warning("invalid integer env var %s=%r, using %s", name, os.getenv(name), default)
        return default


@app.middleware("http")
async def metrics_middleware(request: Request, call_next: Callable) -> Response:
    method = request.method
    started_at = time.monotonic()
    status = "500"

    try:
        response = await call_next(request)
        status = str(response.status_code)
        return response
    finally:
        path = _route_path(request)
        REQUEST_COUNT.labels(method=method, path=path, status=status).inc()
        REQUEST_LATENCY.labels(method=method, path=path).observe(time.monotonic() - started_at)


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    delay_ms = _env_int("HEALTH_LATENCY_MS", 0)
    if delay_ms > 0:
        await asyncio.sleep(delay_ms / 1000)
    return {"status": "ok"}


@app.get("/readyz")
async def readyz() -> dict[str, str]:
    return {"status": "ready"}


@app.get("/reservations/{reservation_id}")
async def get_reservation(reservation_id: str) -> dict[str, str | int]:
    upstream_delay_ms = _env_int("UPSTREAM_DELAY_MS", 120)
    upstream_timeout_ms = _env_int("UPSTREAM_TIMEOUT_MS", 1000)

    await asyncio.sleep(upstream_delay_ms / 1000)

    if upstream_delay_ms > upstream_timeout_ms:
        logger.error(
            "reservation lookup timed out reservation_id=%s upstream_delay_ms=%s upstream_timeout_ms=%s",
            reservation_id,
            upstream_delay_ms,
            upstream_timeout_ms,
        )
        raise HTTPException(status_code=504, detail="reservation dependency timed out")

    logger.info("reservation lookup succeeded reservation_id=%s", reservation_id)
    return {
        "reservation_id": reservation_id,
        "status": "confirmed",
        "upstream_delay_ms": upstream_delay_ms,
    }


@app.get("/metrics")
async def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

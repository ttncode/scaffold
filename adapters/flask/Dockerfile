# syntax=docker/dockerfile:1

# python3.13-bookworm-slim is not published for this uv release — only
# python3.13-trixie-slim is; python:3.13-slim below already resolves to
# slim-trixie, so this keeps both stages on the same Debian release.
FROM ghcr.io/astral-sh/uv:0.12.13-python3.13-trixie-slim@sha256:c0ba49559fc5622531fd05a5747b52afb49ffa883574bbf8eb719ebd103efb84 AS deps
WORKDIR /app
COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --locked --no-dev --no-install-project

FROM python:3.13-slim@sha256:9d2e5553305c7c7b0097999bb17187c69b921ccd6bc9d40e4bb5ebe652c00285 AS runtime
# @SERVICE_SETUP@
WORKDIR /app
COPY --from=deps /app/.venv ./.venv
COPY . .
ENV PATH="/app/.venv/bin:${PATH}"
RUN useradd --create-home --uid 10001 app
USER app
EXPOSE 8080
# python, not wget or curl: the slim image ships neither.
HEALTHCHECK --interval=30s --timeout=3s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health/live')" || exit 1
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "app:create_app()"]

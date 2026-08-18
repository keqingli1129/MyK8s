FROM python:3.12-slim

# uv, pinned to the version that produced uv.lock
COPY --from=ghcr.io/astral-sh/uv:0.8.15 /uv /uvx /bin/

WORKDIR /app

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/app/.venv

# Dependencies first, so this layer is cached across source-only changes
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

# Source last
COPY app.py ./

# Run unprivileged; high UID so K8s runAsNonRoot is satisfied
RUN useradd --create-home --uid 10001 app && chown -R app:app /app
USER app

ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8080
CMD ["gunicorn", "-b", "0.0.0.0:8080", \
     "--workers", "2", "--threads", "4", \
     "--timeout", "30", "--graceful-timeout", "30", \
     "--access-logfile", "-", "--error-logfile", "-", \
     "app:app"]

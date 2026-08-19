# Build in one stage and run in another, so the district's root CAs -- needed to fetch
# packages, and able to sign a certificate for any hostname -- never reach the runtime image.

FROM python:3.12-slim AS builder

# The district network intermittently terminates TLS and re-signs it with a self-signed root
# (CN=FBISD_PA_Trust). Windows trusts it, this image does not, so every HTTPS fetch in a RUN
# step dies with CERTIFICATE_VERIFY_FAILED "self-signed certificate in certificate chain".
# build.ps1 exports the group-policy roots into certs/ before each build. The directory is
# copied whole rather than globbed so a build off the district network -- empty certs/ --
# still works; update-ca-certificates ignores anything that is not a .crt.
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates

# pip carries its own certifi bundle and uv its own webpki-roots; neither reads the system
# store unless told to. uv honors SSL_CERT_FILE, pip honors PIP_CERT.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# uv, pinned to the version that produced uv.lock. Installed from PyPI rather than
# copied from ghcr.io/astral-sh/uv: registry pulls happen daemon-side, where the
# build script's --add-host pins do not apply, and ghcr.io resolution is unreliable here.
RUN pip install --no-cache-dir uv==0.8.15

WORKDIR /app

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/app/.venv

# Dependencies only. Nothing from the source tree is copied here, so this layer stays cached
# across source-only changes.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev


# Same base image and same venv path as the builder: the venv holds absolute paths in its
# script shebangs and expects an interpreter matching the one it was built against.
FROM python:3.12-slim

# Run unprivileged; high UID so K8s runAsNonRoot is satisfied. Created before the copies so
# --chown can set ownership in place, rather than a chown -R duplicating the venv in a layer.
RUN useradd --create-home --uid 10001 app

WORKDIR /app

COPY --from=builder --chown=app:app /app/.venv /app/.venv

# Source last, so a code change rebuilds only this layer
COPY --chown=app:app app.py ./

USER app

ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8080
CMD ["gunicorn", "-b", "0.0.0.0:8080", \
     "--workers", "2", "--threads", "4", \
     "--timeout", "30", "--graceful-timeout", "30", \
     "--access-logfile", "-", "--error-logfile", "-", \
     "app:app"]

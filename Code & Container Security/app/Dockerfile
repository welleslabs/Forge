# Nimbus AI Chat Service — container image
#
# An intentionally insecure build for the shift-left scanner demo. It is written
# so that `docker build` succeeds with no unreachable hosts — the image can be
# built locally and scanned live into Trend Vision One Container Security — while
# still carrying real, detectable problems (baked secrets, outdated vulnerable
# dependencies, runs as root, broad build-context copy).

# Pinned to an old, end-of-life Python 3.9 base: the image inherits a large set of
# real OS-package CVEs that tmas surfaces in the live scan.
FROM python:3.9-slim

# Bake service configuration and secrets into the image. Secrets in ENV persist in
# the image layers — flagged by the Dockerfile linter (mock) and, via the copied
# source below, by tmas secret detection (live).
ENV APP_ENV=production
ENV NIMBUS_API_KEY=sk-live-9f8a7c2b1e4d6a3f5c8b0d2e7a1f4c9b3e6d8a0f2c5b7e9
ENV AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

WORKDIR /app

# Stage the reranker "model weights" artifact. Generated locally at build time so
# the build needs no network and is reproducible anywhere; app.py then loads it
# with an unsafe pickle.load (see the source scan).
RUN mkdir -p /models \
 && python -c "import pickle; pickle.dump({'weights': [0.1] * 8, 'version': '0.4.2'}, open('/models/reranker.pkl', 'wb'))"

# Plant the industry-standard EICAR antivirus test file as a "downloaded model shard".
# It is completely harmless, but every AV engine — including the one tmas's malware scan
# (-M) uses — detects it, so the live scan reports a real malware finding instead of 0.
# Decoded from base64 at build time so the raw signature never sits on the build host
# (which, on a Trend-protected Mac, would otherwise be quarantined by the endpoint agent).
RUN echo 'WDVPIVAlQEFQWzRcUFpYNTQoUF4pN0NDKTd9JEVJQ0FSLVNUQU5EQVJELUFOVElWSVJVUy1URVNULUZJTEUhJEgrSCo=' \
 | base64 -d > /models/reranker-shard.bin

COPY requirements.txt .

# Install the intentionally outdated, vulnerable pinned dependencies. --no-deps keeps
# the exact pins the scanner flags (and that the CVE database matches) without pulling
# a conflicting transitive tree; the sample app is scan-source and is never executed.
RUN pip install --no-cache-dir --no-deps -r requirements.txt

# Copy the entire build context into the image (bad practice: can drag in secrets and
# files the service does not need).
COPY . .

EXPOSE 8080

# No USER directive — the service runs as the built-in root user (bad practice).
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]

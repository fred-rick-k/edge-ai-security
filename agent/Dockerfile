# agent/Dockerfile
# Sandbox image for the camera agent (Session 3-5i).
# Built on the Jetson by scripts/16-install-agent-sandbox.sh and passed to
# `openshell sandbox create --from`.
#
# Session 3-5i: no OpenCV, no psycopg2, no cryptography — the agent only needs
# `requests` (HTTP GET /frame.jpg → POST /v1/chat/completions → POST /events).
# libglib2.0-0t64 is also dropped because it was only needed by OpenCV.
#
FROM nvcr.io/nvidia/base/ubuntu:24.04

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Least privilege: replace the base image's "ubuntu" user (uid 1000, member of
# sudo/adm/dialout/...) with a dedicated "agent" user at the same uid and NO
# supplementary groups.
RUN (userdel -r ubuntu || true) \
 && (groupdel ubuntu 2>/dev/null || true) \
 && groupadd -g 1000 agent \
 && useradd -u 1000 -g 1000 -M -d /sandbox -s /bin/bash agent

COPY requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/agent-venv \
 && /opt/agent-venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt

# COPY keeps the build-context mode. The workspace files are 0700, so the file needs --chmod.
# --chmod ALSO applied 0644 to the implicitly created /app directory (no x bit: uid 1000 could not
# traverse it, "can't open file '/app/agent.py': [Errno 13]", python exit 2; probe in stage 3-5i,
# 7-2d full-flow run, 2026-11-03). So create /app with 0755 first; COPY into an existing directory
# does not change the directory's mode.
RUN mkdir -p /app && chmod 0755 /app
COPY --chmod=0644 agent.py /app/agent.py
RUN mkdir -p /sandbox && chown 1000:1000 /sandbox

USER 1000:1000
# No ENTRYPOINT/CMD: OpenShell starts the command given after `--` as the main process.

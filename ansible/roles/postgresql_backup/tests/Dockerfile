# Image de test : Ubuntu 24.04 (OS des EC2) + PostgreSQL 16, age, shellcheck.
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends postgresql-16 postgresql-client-16 age jq ca-certificates shellcheck python3 >/dev/null && rm -rf /var/lib/apt/lists/*

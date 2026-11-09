# Offline Buzz relay bundle — operator entry points.
#
#   make bundle ARCH=arm64        build release assets locally (docker save)
#   make install HOST=10.0.0.5    load images, write .env, start, verify
#   make verify                   quick checks (HTTP, web UI, WS upgrade)
#   make verify-deep              NIP-42 auth + publish + read-back
#   make logs / make down / make backup
#
# Everything after `install` works with no internet.

SHELL := /bin/bash
OF   := .
ARCH ?= $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
HOST ?= 127.0.0.1
PORT ?= 80
RELEASE_LOCAL ?= local-$(shell date -u +%Y%m%d-%H%M%S)

.PHONY: bundle install verify verify-deep logs down status backup

bundle:
	./scripts/package-images.sh $(ARCH) $(RELEASE_LOCAL) ./dist

install:
	./scripts/install.sh --host $(HOST) --port $(PORT)

verify:
	./scripts/verify.sh

verify-deep:
	python3 ./scripts/verify-nip42.py "$$(sed -nE 's/^RELAY_URL=//p' .env | head -1)"

logs:
	docker compose -f compose.yml logs -f relay

status:
	docker compose -f compose.yml ps

down:
	docker compose -f compose.yml down

backup:
	./scripts/backup.sh

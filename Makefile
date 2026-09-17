# Chart-review platform — common development tasks.
#
#   make help     list targets
#   make setup    install JS workspace + Python sidecar
#   make check    everything CI runs (typecheck, tests, build)

.DEFAULT_GOAL := help
SHELL := /bin/bash
PY := python/.venv/bin/python

.PHONY: help setup setup-js setup-py dev check typecheck test test-py test-ui \
        build docker-build docker-up docker-down clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

## ---- setup ---------------------------------------------------------

setup: setup-js setup-py ## Install all dependencies (JS + Python)

setup-js: ## Install the npm workspace
	npm ci

setup-py: ## Create the sidecar venv and install it with test extras
	cd python && python3 -m venv .venv
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -e "python[dev]"

## ---- develop -------------------------------------------------------

dev: ## Run server (:3002) + client (:5174) with hot reload
	npm run dev

## ---- verify --------------------------------------------------------

check: typecheck test test-py build ## Everything CI runs — run before pushing

typecheck: ## tsc --noEmit across all workspace packages
	npm run typecheck

test: ## Vitest — TS unit + React component tests
	npm test

test-py: ## pytest — Python agent sidecar
	cd python && $(CURDIR)/$(PY) -m pytest

test-ui: ## Playwright — Studio UI end-to-end (needs a running server)
	npm run test:ui

build: ## Production client bundle
	npm run build:client

## ---- container -----------------------------------------------------

docker-build: ## Build the single portable image
	docker build -t chart-review:local .

docker-up: ## Run the stack (data persists in ./data)
	docker compose up --build

docker-down: ## Stop the stack
	docker compose down

## ---- housekeeping --------------------------------------------------

clean: ## Remove build output and runtime state (keeps node_modules)
	rm -rf dist var

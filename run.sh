#!/bin/bash

docker run -d -p 6379:6379 redis:7-alpine
uv run uvicorn fastapi_app:app --reload --host 0.0.0.0 --port 8080

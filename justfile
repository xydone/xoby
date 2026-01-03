set dotenv-load := false

MIGRATIONS_DIR := "migrations"

# database migrations
migrate-up:
    @just _migrate up .env

migrate-create name:
    goose -dir {{ MIGRATIONS_DIR }} create {{ name }} sql

migrate-down:
    @just _migrate down .env

migrate-status:
    @just _migrate status .env

migrate-test-up:
    @just _migrate up .testing.env

migrate-test-down:
    @just _migrate down .testing.env

migrate-test-status:
    @just _migrate status .testing.env

_migrate command env_file:
    @set -a && [ -f {{ env_file }} ] && . ./{{ env_file }} && set +a && \
    goose -dir {{ MIGRATIONS_DIR }} postgres \
    "user=$DATABASE_USERNAME dbname=$DATABASE_NAME host=$DATABASE_HOST port=$DATABASE_PORT password=$DATABASE_PASSWORD sslmode=disable" \
    {{ command }}

# container management
container-start:
    podman compose --profile prod start

container-stop:
    podman compose --profile prod stop

container-up:
    podman compose --profile prod up -d

container-down:
    podman compose --profile prod down -v

container-test-up:
    podman compose --env-file .testing.env --profile test up -d

container-test-down:
    podman compose --profile test down -v

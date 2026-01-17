set dotenv-load := false

MIGRATIONS_DIR := justfile_directory() + "/migrations"

[no-cd]
migrate-up:
    @just _migrate up .env

[no-cd]
migrate-create name:
    goose -dir {{ MIGRATIONS_DIR }} create {{ name }} sql

[no-cd]
migrate-down:
    @just _migrate down .env

[no-cd]
migrate-status:
    @just _migrate status .env

[no-cd]
migrate-test-up:
    @just _migrate up .testing.env

[no-cd]
migrate-test-down:
    @just _migrate down .testing.env

[no-cd]
migrate-test-status:
    @just _migrate status .testing.env

[no-cd]
_migrate command env_file:
    @set -a && [ -f {{ env_file }} ] && . ./{{ env_file }} && set +a && \
    goose -dir {{ MIGRATIONS_DIR }} postgres \
    "user=$DATABASE_USERNAME dbname=$DATABASE_NAME host=$DATABASE_HOST port=$DATABASE_PORT password=$DATABASE_PASSWORD sslmode=disable" \
    {{ command }}

[no-cd]
container-start:
    podman compose --profile prod start

[no-cd]
container-stop:
    podman compose --profile prod stop

[no-cd]
container-up:
    podman compose --profile prod up -d

[no-cd]
container-down:
    podman compose --profile prod down -v

[no-cd]
container-test-up:
    podman compose --env-file .testing.env --profile test up -d

[no-cd]
container-test-down:
    podman compose --profile test down -v

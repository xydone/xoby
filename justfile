set dotenv-load := false

MIGRATIONS_DIR := justfile_directory() + "/migrations"

# start prod container and run migrations
up: container-up
    @just migrate-up

# start test container and run migrations
test: container-test-up
    @just migrate-test-up

# stop all containers and delete their volumes
clean: container-down container-test-down

migrate-up:
    @just _migrate up .env

migrate-down:
    @just _migrate down .env

migrate-status:
    @just _migrate status .env

migrate-create name:
    goose -dir {{ MIGRATIONS_DIR }} create {{ name }} sql

migrate-test-up:
    @just _migrate up .testing.env

migrate-test-down:
    @just _migrate down .testing.env

migrate-test-status:
    @just _migrate status .testing.env

# start prod container
container-up:
    podman compose --profile prod up -d --wait

# stop and remove the volume of the prod container
container-down:
    podman compose --profile prod down -v

# start test container
container-test-up:
    podman compose --env-file .testing.env --profile test up -d --wait

# stop and remove the volume of the test container
container-test-down:
    podman compose --profile test down -v

_migrate command env_file:
    @echo "Running '{{ command }}' using {{ env_file }}..."
    @set -a && [ -f {{ env_file }} ] && . ./{{ env_file }} && set +a && \
    goose -dir {{ MIGRATIONS_DIR }} postgres \
    "user=$DATABASE_USERNAME dbname=$DATABASE_NAME host=$DATABASE_HOST port=$DATABASE_PORT password=$DATABASE_PASSWORD sslmode=disable" \
    {{ command }}

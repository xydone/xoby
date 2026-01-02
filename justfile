set dotenv-load := true

DB_CONN := "user=" + env("DATABASE_USERNAME") + " dbname=" + env("DATABASE_NAME") + " host=" + env("DATABASE_HOST") + " port=" + env("DATABASE_PORT") + " password=" + env("DATABASE_PASSWORD") + " sslmode=disable"
MIGRATIONS_DIR := "migrations"

# goose up
up:
    goose -dir {{ MIGRATIONS_DIR }} postgres "{{ DB_CONN }}" up

# goose down
down:
    goose -dir {{ MIGRATIONS_DIR }} postgres "{{ DB_CONN }}" down

# goose status
status:
    goose -dir {{ MIGRATIONS_DIR }} postgres "{{ DB_CONN }}" status

# goose create
create name:
    goose -dir {{ MIGRATIONS_DIR }} create {{ name }} sql

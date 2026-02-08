-- +goose Up
SELECT
  'up SQL query';

-- extensions
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.immutable_unaccent(text)
RETURNS text AS $$
    SELECT public.unaccent($1);
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
-- +goose StatementEnd

-- auth schema
CREATE SCHEMA
  auth;

CREATE TYPE
  auth.user_role AS ENUM('user', 'admin');

CREATE TABLE
  auth.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    display_name character varying(255) NOT NULL,
    username character varying(255) NOT NULL,
    password character varying(255) NOT NULL,
    role auth.user_role DEFAULT 'user' NOT NULL
  );

CREATE TABLE
  auth.api_keys (
    id integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    public_id character varying(20) NOT NULL,
    secret_hash bytea NOT NULL,
    permissions auth.user_role NOT NULL
  );

-- when a user's role changes, cull all of their old highly privileged roles
-- if they happen to get demoted.
-- +goose StatementBegin
CREATE FUNCTION
  auth.on_user_role_change () RETURNS TRIGGER AS $$
BEGIN
    IF OLD.role IS DISTINCT FROM NEW.role AND NEW.role < OLD.role THEN
        DELETE FROM auth.api_keys
        WHERE user_id = NEW.id 
          AND permissions > NEW.role;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- +goose StatementEnd
CREATE TRIGGER
  trg_cleanup_api_keys
AFTER
UPDATE
  OF role ON auth.users FOR EACH ROW
EXECUTE
  FUNCTION auth.on_user_role_change ();

-- content schema, includes media such as movies, manga, etc.
CREATE SCHEMA
  content;

CREATE TYPE
  content.media_type AS ENUM('movie', 'book', 'comic', 'manga');

CREATE TABLE
  content.media_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
    user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    description TEXT,
    release_date DATE,
    media_type content.media_type NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),

    search_vector tsvector GENERATED ALWAYS AS (
      setweight(to_tsvector('english', public.immutable_unaccent(title)), 'A') ||
      setweight(to_tsvector('english', coalesce(extract(year from release_date)::text, '')), 'B')
    ) STORED
  );

CREATE INDEX idx_media_search_vector ON content.media_items USING GIN (search_vector);
CREATE INDEX idx_media_title_trgm ON content.media_items USING GIN (title gin_trgm_ops);

CREATE TABLE
  content.movies (
    media_id uuid PRIMARY KEY REFERENCES content.media_items (id) ON DELETE CASCADE,
    runtime_minutes INTEGER
  );

CREATE TABLE
  content.media_genres (
    name TEXT NOT NULL,
    media_id uuid REFERENCES content.media_items (id) ON DELETE CASCADE,
    UNIQUE (name, media_id)
  );

CREATE TABLE
  content.books (
    media_id uuid PRIMARY KEY REFERENCES content.media_items (id) ON DELETE CASCADE,
    total_pages INTEGER
  );

CREATE TABLE
  content.manga (
    media_id uuid PRIMARY KEY REFERENCES content.media_items (id) ON DELETE CASCADE,
    total_chapters INTEGER
  );


CREATE SCHEMA
  collectors;

CREATE TYPE
  collectors.status AS ENUM('completed', 'pending', 'todo');

CREATE TABLE
  collectors.list (
    provider TEXT NOT NULL,
    external_id TEXT NOT NULL,
    media_type content.media_type NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    status collectors.status DEFAULT 'todo' NOT NULL,
    priority INT NOT NULL DEFAULT 0,
    PRIMARY KEY (provider, external_id)
  );

-- staff and organisations
CREATE TABLE
  content.people (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
    full_name TEXT NOT NULL,
    bio TEXT,
    provider TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
  );


CREATE TABLE
  content.media_staff (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
    media_id uuid REFERENCES content.media_items (id) ON DELETE CASCADE,
    person_id uuid REFERENCES content.people (id) ON DELETE CASCADE,
    role_name TEXT NOT NULL,
    character_name TEXT,
    UNIQUE NULLS NOT DISTINCT (media_id, person_id, role_name, character_name)
  );

CREATE TYPE
  content.image_type AS ENUM('backdrop', 'logo', 'poster', 'cover');

CREATE TABLE
  content.image_providers (
    name TEXT PRIMARY KEY,
    is_external BOOLEAN DEFAULT true NOT NULL
  );

-- defaults
INSERT INTO
  content.image_providers (name, is_external)
VALUES
  ('local', false),
  ('tmdb', true),
  ('anilist', true);

CREATE TABLE
  content.media_images (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
    media_id uuid NOT NULL REFERENCES content.media_items (id) ON DELETE CASCADE,
    image_type content.image_type NOT NULL,
    provider_name TEXT NOT NULL REFERENCES content.image_providers (name),
    path TEXT NOT NULL,
    is_primary BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT now()
  );

CREATE TABLE
  content.organizations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
  );

CREATE TABLE
  content.media_organizations (
    media_id uuid REFERENCES content.media_items (id) ON DELETE CASCADE,
    organization_id uuid REFERENCES content.organizations (id) ON DELETE CASCADE,
    role_name TEXT NOT NULL,
    PRIMARY KEY (media_id, organization_id, role_name)
  );

-- profiles
CREATE SCHEMA
  profiles;

CREATE TYPE profiles.progress_unit AS ENUM ('quantity', 'percentage');
CREATE TABLE profiles.progress (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
    user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE,
    media_id uuid REFERENCES content.media_items (id) ON DELETE CASCADE,
    status TEXT CHECK (status IN ('planned', 'in_progress', 'completed', 'dropped')),
    -- in case of quantity, should be an integer
    -- it will be a quantity when, for example, it is a manga - it represents the read chapters
    -- in the case of percentage, its the completion percentage
    -- it will be a percentage in the case of, for example, books
    progress_value FLOAT NOT NULL,
    progress_unit profiles.progress_unit NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_progress_latest ON profiles.progress (user_id, media_id, created_at DESC);

-- +goose StatementBegin
-- because progress can have different types, we use this view to normalize things
CREATE OR REPLACE VIEW profiles.progress_summary AS
SELECT 
    p.user_id,
    p.media_id,
    m.media_type,
    p.status,
    p.progress_value,
    p.progress_unit,
    CASE 
        -- if its a percentage, enforce 0-1
        -- query shortcircuits here if its a percentage
        WHEN p.progress_unit = 'percentage' THEN LEAST(p.progress_value, 1.0)
        -- we take read value as page/total
        WHEN m.media_type = 'manga' AND ma.total_chapters > 0 THEN 
            LEAST(p.progress_value / ma.total_chapters, 1.0)
        -- we take read value as page/total
        WHEN m.media_type = 'book' AND b.total_pages > 0 THEN 
            LEAST(p.progress_value / b.total_pages, 1.0)
        -- when no totals, either completed or not
        ELSE (CASE WHEN p.status = 'completed' THEN 1.0 ELSE 0 END)
    END AS completion_percentage
FROM profiles.progress p
JOIN content.media_items m ON p.media_id = m.id
LEFT JOIN content.manga ma ON m.id = ma.media_id
LEFT JOIN content.books b ON m.id = b.media_id;
-- +goose StatementEnd

CREATE TABLE
  profiles.ratings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
    user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE,
    media_id uuid REFERENCES content.media_items (id) ON DELETE CASCADE,
    rating_score INTEGER CHECK (rating_score BETWEEN 1 AND 10),
    created_at TIMESTAMPTZ DEFAULT now()
  );

CREATE TABLE
  profiles.lists (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
    user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    is_public BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now()
  );

CREATE TABLE
  profiles.lists_items (
    list_id uuid REFERENCES profiles.lists (id) ON DELETE CASCADE,
    media_id uuid REFERENCES content.media_items (id) ON DELETE CASCADE,
    position INTEGER,
    added_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (list_id, media_id)
  );

--- meant to cover all of the data that comes down from external sources
CREATE SCHEMA
  external;

CREATE TABLE
  external.media (
    media_id uuid REFERENCES content.media_items (id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    external_id TEXT NOT NULL,
    last_synced_at TIMESTAMPTZ,
    PRIMARY KEY (media_id, provider),
    UNIQUE (provider, external_id)
  );

-- index for over time scanning
CREATE INDEX
  idx_mappings_sync ON external.media (last_synced_at)
WHERE
  last_synced_at IS NULL;

CREATE TABLE
  external.people (
    person_id uuid REFERENCES content.people (id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    external_id TEXT NOT NULL,
    PRIMARY KEY (person_id, provider),
    UNIQUE (provider, external_id)
  );

CREATE TABLE external.progress_mapping (
    progress_id uuid REFERENCES profiles.progress (id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    -- some sort of unique identifier (ex. the letterboxd link)
    external_id TEXT NOT NULL,
    PRIMARY KEY (progress_id, provider, external_id)
);

-- +goose Down
SELECT
  'down SQL query';

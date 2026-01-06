-- +goose Up
SELECT 'up SQL query';

-- auth schema
CREATE SCHEMA auth;

CREATE TABLE auth.users (
id integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
created_at timestamp without time zone DEFAULT now () NOT NULL,
display_name character varying (255) NOT NULL,
username character varying (255) NOT NULL,
password character varying (255) NOT NULL
) ;


CREATE TABLE auth.api_keys (
id integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
created_at timestamp without time zone DEFAULT now () NOT NULL,
user_id integer NOT NULL,
public_id character varying (20) NOT NULL,
secret_hash bytea NOT NULL
) ;

-- content schema, includes media such as movies, manga, etc.
CREATE SCHEMA content ;

CREATE TABLE content.media_items (
id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
user_id integer REFERENCES auth.users (id) ON DELETE CASCADE,
title TEXT NOT NULL,
release_date DATE,
cover_image_url TEXT,
media_type TEXT NOT NULL CHECK (media_type IN ('movie',
'book',
'comic',
'manga')),
created_at TIMESTAMPTZ DEFAULT now ()
) ;

CREATE TABLE content.movies (
media_id uuid PRIMARY KEY REFERENCES content.media_items (id) ON DELETE CASCADE,
runtime_minutes INTEGER
) ;

CREATE TABLE content.books (
media_id uuid PRIMARY KEY REFERENCES content.media_items (id) ON DELETE CASCADE,
page_count INTEGER
) ;

-- staff and organisations

CREATE TABLE content.people (
id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
full_name TEXT NOT NULL,
bio TEXT,
created_at TIMESTAMPTZ DEFAULT now ()
) ;

CREATE TABLE content.media_staff (
media_id uuid REFERENCES content.media_items (id) ON DELETE CASCADE,
person_id uuid REFERENCES content.people (id) ON DELETE CASCADE,
role_name TEXT NOT NULL,
PRIMARY KEY (media_id, person_id, role_name)
) ;


CREATE TABLE content.organizations (
id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
name TEXT NOT NULL,
created_at TIMESTAMPTZ DEFAULT now ()
) ;

CREATE TABLE content.media_organizations (
media_id uuid REFERENCES content.media_items (id) ON DELETE CASCADE,
organization_id uuid REFERENCES content.organizations (id) ON DELETE CASCADE,
role_name TEXT NOT NULL,
PRIMARY KEY (media_id, organization_id, role_name)
) ;


-- profiles
CREATE SCHEMA profiles ;

CREATE TABLE profiles.user_media_progress (
user_id integer REFERENCES auth.users (id) ON DELETE CASCADE,
media_id uuid REFERENCES content.media_items (id) ON DELETE CASCADE,
status TEXT CHECK (status IN ('planned', 'watching', 'completed', 'dropped')),
progress_value INTEGER DEFAULT 0,
updated_at TIMESTAMPTZ DEFAULT now (),
PRIMARY KEY (user_id, media_id)
) ;

CREATE TABLE profiles.ratings (
user_id integer REFERENCES auth.users (id) ON DELETE CASCADE,
media_id uuid REFERENCES content.media_items (id) ON DELETE CASCADE,
rating_score INTEGER CHECK (rating_score BETWEEN 1 AND 10),
created_at TIMESTAMPTZ DEFAULT now (),
PRIMARY KEY (user_id, media_id)
) ;

CREATE TABLE profiles.lists (
id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
user_id integer REFERENCES auth.users (id) ON DELETE CASCADE,
name TEXT NOT NULL,
is_public BOOLEAN DEFAULT true,
created_at TIMESTAMPTZ DEFAULT now ()
) ;

CREATE TABLE profiles.lists_items (
collection_id uuid REFERENCES profiles.lists (id) ON DELETE CASCADE,
media_id uuid REFERENCES content.media_items (id) ON DELETE CASCADE,
PRIMARY KEY (collection_id, media_id)
) ;

-- +goose Down
SELECT 'down SQL query' ;

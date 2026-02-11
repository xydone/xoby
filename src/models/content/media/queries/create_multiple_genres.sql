INSERT INTO
  content.media_genres (media_id, name)
SELECT
  media_id,
  genre_name
FROM
  UNNEST(
    $1::uuid[],
    $2::text[]
  ) AS val (
    media_id,
    genre_name
  )
ON CONFLICT (name, media_id) DO NOTHING;

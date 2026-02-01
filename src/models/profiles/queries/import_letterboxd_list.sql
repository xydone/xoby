WITH
  input_data AS (
    SELECT
      t.title,
      t.release_year,
      t.created_at
    FROM
      unnest($3::text[], $4::bigint[], $5::timestamptz[]) AS t (title, release_year, created_at)
  ),
  matches AS (
    SELECT
      i.title,
      i.release_year,
      i.created_at,
      m.id AS media_id,
      COUNT(m.id) OVER (
        PARTITION BY
          i.title,
          i.release_year,
          i.created_at
      ) AS match_count
    FROM
      input_data i
      LEFT JOIN content.media_items m ON m.media_type = 'movie'
      AND m.title = i.title
      AND (
        i.release_year IS NULL
        OR EXTRACT(
          YEAR
          FROM
            m.release_date
        ) = i.release_year
      )
  ),
  inserted AS (
    INSERT INTO
      profiles.lists_items (list_id, media_id)
    SELECT
      $2::uuid,
      media_id
    FROM
      matches
    WHERE
      match_count = 1
      AND media_id IS NOT NULL
      AND EXISTS (
        SELECT
          1
        FROM
          profiles.lists l
        WHERE
          l.id = $2
          AND l.user_id = $1
      ) ON CONFLICT
    DO
      NOTHING
    RETURNING
      media_id
  )
SELECT
  title,
  release_year,
  created_at,
  match_count
FROM
  matches
WHERE
  match_count <> 1;

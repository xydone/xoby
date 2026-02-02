WITH
  input_list AS (
    SELECT
      title,
      yr,
      c_at,
      row_number() OVER () as input_row_id
    FROM
      unnest($1::text[], $2::bigint[], $3::timestamptz[]) AS t (title, yr, c_at)
  ),
  match_analysis AS (
    SELECT
      i.input_row_id,
      i.title,
      i.yr,
      i.c_at,
      m.id AS media_id,
      COUNT(m.id) OVER (
        PARTITION BY
          i.input_row_id
      ) as match_count
    FROM
      input_list i
      LEFT JOIN content.media_items m ON m.title = i.title
      AND m.media_type = 'movie'
      AND (
        i.yr IS NULL
        OR EXTRACT(
          YEAR
          FROM
            m.release_date
        ) = i.yr
      )
  ),
  insertion_step AS (
    INSERT INTO
      profiles.progress (user_id, media_id, status, created_at)
    SELECT
      $4,
      media_id,
      $5,
      COALESCE(c_at, CURRENT_TIMESTAMP)
    FROM
      match_analysis
    WHERE
      match_count = 1
    RETURNING
      media_id
  )
SELECT DISTINCT
  ON (input_row_id) title,
  yr AS release_year
FROM
  match_analysis
WHERE
  match_count != 1
ORDER BY
  input_row_id;

WITH
  input_list AS (
    SELECT
      title,
      yr,
      c_at,
      val,
      row_number() OVER () as input_row_id
    FROM
      unnest(
        $2::text[],
        $3::bigint[],
        $4::timestamptz[],
        $5::integer[]
      ) AS t (title, yr, c_at, val)
  ),
  match_analysis AS (
    SELECT
      i.input_row_id,
      i.title,
      i.yr,
      i.c_at,
      i.val,
      m.id AS media_id,
      COUNT(m.id) OVER (
        PARTITION BY
          i.input_row_id
      ) as match_count,
      EXISTS (
        SELECT
          1
        FROM
          profiles.ratings r
        WHERE
          r.user_id = $1
          AND r.media_id = m.id
      ) as already_rated
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
      profiles.ratings (user_id, media_id, rating_score, created_at)
    SELECT
      $1,
      media_id,
      val,
      COALESCE(c_at, CURRENT_TIMESTAMP)
    FROM
      match_analysis
    WHERE
      match_count = 1
      AND NOT already_rated
    RETURNING
      media_id
  )
SELECT DISTINCT
  ON (input_row_id) title,
  yr AS release_year,
  CASE
    WHEN match_count = 0 THEN 'Movie not found'
    WHEN match_count > 1 THEN 'Multiple matches found'
    WHEN already_rated THEN 'Already rated'
  END as reason
FROM
  match_analysis
WHERE
  match_count != 1
  OR already_rated
ORDER BY
  input_row_id;

WITH
  input_list AS (
    SELECT
      title,
      yr,
      c_at,
      ext_id,
      row_number() OVER () as input_row_id
    FROM
      unnest(
        $1::text[],
        $2::bigint[],
        $3::timestamptz[],
        $4::text[]
      ) AS t (title, yr, c_at, ext_id)
  ),
  match_analysis AS (
    SELECT
      i.*,
      m.id AS media_id,
      COUNT(m.id) OVER (
        PARTITION BY
          i.input_row_id
      ) as match_count,
      EXISTS (
        SELECT
          1
        FROM
          external.progress_mapping pm
        WHERE
          pm.external_id = i.ext_id
          AND pm.provider = $7
      ) as already_imported
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
      profiles.progress (user_id, media_id, status, created_at, progress_value, progress_unit)
    SELECT
      $5,
      media_id,
      $6::profiles.progress_status,
      COALESCE(c_at, CURRENT_TIMESTAMP),
      CASE WHEN $6::profiles.progress_status = 'completed' THEN 1.0 ELSE 0.0 END,
      'percentage'::profiles.progress_unit
    FROM
      match_analysis
    WHERE
      match_count = 1
      AND NOT already_imported
    RETURNING
      id,
      media_id,
      created_at
  ),
  mapping_step AS (
    INSERT INTO
      external.progress_mapping (progress_id, provider, external_id)
    SELECT
      ins.id,
      $7,
      ma.ext_id
    FROM
      insertion_step ins
      JOIN match_analysis ma ON ins.media_id = ma.media_id
      AND ins.created_at = COALESCE(ma.c_at, ins.created_at)
  )
SELECT DISTINCT
  ON (input_row_id) title,
  yr AS release_year,
  CASE
    WHEN already_imported THEN 'Already imported'
    WHEN match_count = 0 THEN 'Movie not found'
    WHEN match_count > 1 THEN 'Multiple matches found'
  END as reason
FROM
  match_analysis
WHERE
  match_count != 1
  OR already_imported
ORDER BY
  input_row_id;

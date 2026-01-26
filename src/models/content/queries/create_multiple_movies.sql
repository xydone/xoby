WITH
  input_rows AS (
    SELECT
      id_idx as row_idx,
      gen_random_uuid () AS new_id,
      val.title,
      NULLIF(val.rel_date, '')::date AS release_date,
      val.runtime::integer AS runtime,
      val.description,
      val.provider,
      val.ext_id
    FROM
      UNNEST(
        $1::text[],
        $3::text[],
        $4::bigint[],
        $5::text[],
        $6::text[],
        $7::text[]
      )
    WITH
      ORDINALITY AS val (
        title,
        rel_date,
        runtime,
        description,
        provider,
        ext_id,
        id_idx
      )
  ),
  inserted_media AS (
    INSERT INTO
      content.media_items (
        id,
        user_id,
        title,
        description,
        release_date,
        media_type
      )
    SELECT
      new_id,
      $2::uuid,
      title,
      description,
      release_date,
      'movie'::content.media_type
    FROM
      input_rows
  ),
  inserted_movies AS (
    INSERT INTO
      content.movies (media_id, runtime_minutes)
    SELECT
      new_id,
      runtime
    FROM
      input_rows
  ),
  inserted_mappings AS (
    INSERT INTO
      content.external_mappings (media_id, provider, external_id, last_synced_at)
    SELECT
      new_id,
      provider,
      ext_id,
      now()
    FROM
      input_rows ON CONFLICT (provider, external_id)
    DO
    UPDATE
    SET
      last_synced_at = EXCLUDED.last_synced_at
  )
SELECT
  new_id
FROM
  input_rows
ORDER BY
  row_idx;

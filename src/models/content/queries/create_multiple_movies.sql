WITH
  raw_input AS (
    SELECT
      id_idx as row_idx,
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
  processed_input AS (
    SELECT
      r.*,
      m.media_id AS existing_id,
      gen_random_uuid () AS generated_id
    FROM
      raw_input r
      LEFT JOIN external.media m ON r.provider = m.provider
      AND r.ext_id = m.external_id
  ),
  final_data AS (
    SELECT
      *,
      COALESCE(existing_id, generated_id) AS target_id,
      (existing_id IS NULL) AS is_new
    FROM
      processed_input
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
      target_id,
      $2::uuid,
      title,
      description,
      release_date,
      'movie'
    FROM
      final_data
    WHERE
      is_new = true
  ),
  inserted_movies AS (
    INSERT INTO
      content.movies (media_id, runtime_minutes)
    SELECT
      target_id,
      runtime
    FROM
      final_data
    WHERE
      is_new = true
  ),
  upserted_mappings AS (
    INSERT INTO
      external.media (media_id, provider, external_id, last_synced_at)
    SELECT
      target_id,
      provider,
      ext_id,
      now()
    FROM
      final_data ON CONFLICT (provider, external_id)
    DO
    UPDATE
    SET
      last_synced_at = EXCLUDED.last_synced_at
  )
SELECT
  target_id as id
FROM
  final_data
ORDER BY
  row_idx;

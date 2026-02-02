WITH
  raw_data AS (
    SELECT
      val.title,
      val.rel_date::DATE as rel_date,
      val.descr,
      val.chapters,
      val.provider,
      val.ext_id,
      val.idx
    FROM
      UNNEST(
        $1::text[],
        $2::text[],
        $3::text[],
        $4::integer[],
        $6::text[],
        $7::text[]
      )
    WITH
      ORDINALITY AS val (
        title,
        rel_date,
        descr,
        chapters,
        provider,
        ext_id,
        idx
      )
  ),
  input_processing AS (
    SELECT DISTINCT
      ON (r.provider, r.ext_id) r.title,
      r.rel_date,
      r.descr,
      r.chapters,
      r.provider,
      r.ext_id,
      r.idx,
      m.media_id AS existing_id,
      gen_random_uuid () AS generated_id
    FROM
      raw_data r
      LEFT JOIN external.media m ON r.provider = m.provider
      AND r.ext_id = m.external_id
    ORDER BY
      r.provider,
      r.ext_id,
      r.idx
  ),
  final_input AS (
    SELECT
      *,
      COALESCE(existing_id, generated_id) AS target_id,
      (existing_id IS NULL) AS is_new
    FROM
      input_processing
  ),
  inserted_media AS (
    INSERT INTO
      content.media_items (
        id,
        title,
        release_date,
        description,
        media_type,
        user_id
      )
    SELECT
      target_id,
      title,
      rel_date,
      descr,
      'manga',
      $5::uuid
    FROM
      final_input
    WHERE
      is_new = true
  ),
  inserted_manga AS (
    INSERT INTO
      content.manga (media_id, total_chapters)
    SELECT
      target_id,
      chapters
    FROM
      final_input
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
      final_input ON CONFLICT (provider, external_id)
    DO
    UPDATE
    SET
      last_synced_at = EXCLUDED.last_synced_at
    RETURNING
      media_id,
      provider,
      external_id
  )
SELECT
  f.target_id as id
FROM
  raw_data r
  JOIN final_input f ON r.provider = f.provider
  AND r.ext_id = f.ext_id
ORDER BY
  r.idx;

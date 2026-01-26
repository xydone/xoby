UPDATE
  collectors.list
SET
  status = 'pending',
  updated_at = now()
WHERE
  (provider, external_id) IN (
    SELECT
      provider,
      external_id
    FROM
      collectors.list
    WHERE
      provider = $1
      AND (
        status = 'todo'
        OR (
          status = 'pending'
          AND updated_at < now() - INTERVAL '1 day'
        )
      )
    ORDER BY
      created_at ASC
    LIMIT
      $2 FOR
    UPDATE
      SKIP LOCKED
  )
RETURNING
  external_id;

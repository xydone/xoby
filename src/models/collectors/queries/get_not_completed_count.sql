SELECT
  count(*) AS total
FROM
  collectors.list
WHERE
  provider = $1
  AND (
    status = $2
    OR (
      $2 = 'todo'
      AND status = 'pending'
      AND updated_at < now() - INTERVAL '1 day'
    )
  );

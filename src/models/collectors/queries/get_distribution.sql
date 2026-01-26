SELECT
  provider,
  COUNT(*) FILTER (WHERE status = 'todo') AS todo,
  COUNT(*) FILTER (WHERE status = 'pending' AND updated_at < now() - INTERVAL '1 day') AS stale,
  COUNT(*) FILTER (WHERE status = 'pending') AS pending,
  COUNT(*) FILTER (WHERE status = 'completed') AS completed,
  COUNT(*) AS total
FROM
  collectors.list
GROUP BY
  provider;

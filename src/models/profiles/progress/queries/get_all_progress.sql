SELECT
  progress_id,
  user_id,
  media_id,
  status,
  progress_value,
  progress_unit,
  completion_percentage,
  created_at
FROM
  profiles.progress_summary
WHERE
  user_id = $1
ORDER BY
  created_at DESC
LIMIT
  $2;

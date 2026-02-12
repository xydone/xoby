SELECT
  id,
  rating_score,
  created_at
FROM
  profiles.ratings
WHERE
  user_id = $1
  AND media_id = $2;

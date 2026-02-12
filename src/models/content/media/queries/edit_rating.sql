UPDATE
  profiles.ratings
SET
  rating_score = $3,
  created_at = now()
WHERE
  id = $1
  AND user_id = $2
RETURNING
  *;

INSERT INTO profiles.progress (user_id, media_id, status, progress_value, progress_unit)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

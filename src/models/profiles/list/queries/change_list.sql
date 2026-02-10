UPDATE profiles.lists 
SET name = $3, is_public = $4
WHERE id = $1 AND user_id = $2
RETURNING id;

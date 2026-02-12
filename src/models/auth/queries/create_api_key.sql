INSERT INTO
  auth.api_keys (user_id, permissions, public_id, secret_hash)
SELECT
  p.id,
  $2,
  $3,
  $4
FROM
  auth.users p
WHERE
  p.id = $1
  AND p.role >= $2;

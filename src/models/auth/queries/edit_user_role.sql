UPDATE
  auth.users
SET role
  = $2
WHERE
  id = $1
RETURNING
  id,
  display_name,
  username,
  role

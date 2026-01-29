INSERT INTO auth.users (display_name, username, role, password)
VALUES ($1,$2,$3,$4)
RETURNING id,display_name,username

SELECT
  *
FROM
  profiles.ratings
WHERE
  user_id = $1;

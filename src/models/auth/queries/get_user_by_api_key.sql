SELECT
  user_id,
  secret_hash,
  permissions
FROM
  auth.api_keys
WHERE
  public_id = $1;

INSERT INTO
  profiles.ratings (user_id, media_id, rating_score)
VALUES
  ($1, $2, $3)
RETURNING
  id;

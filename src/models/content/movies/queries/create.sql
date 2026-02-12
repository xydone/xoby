WITH
  new_media AS (
    INSERT INTO
      content.media_items (
        title,
        user_id,
        release_date,
        media_type,
        description
      )
    VALUES
      ($1, $2, $3::date, 'movie', $5)
    RETURNING
      id,
      title
  )
INSERT INTO
  content.movies (media_id, runtime_minutes)
VALUES
  (
    (
      SELECT
        id
      FROM
        new_media
    ),
    $4
  )
RETURNING
  (
    SELECT
      id
    FROM
      new_media
  ),
  (
    SELECT
      title
    FROM
      new_media
  );

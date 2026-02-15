SELECT
  m.id,
  m.title,
  m.media_type,
  m.release_date,
  img.path AS primary_image_path,
  img.provider_name AS primary_image_provider,
  mov.runtime_minutes,
  bk.total_pages
FROM
  content.media_items m
  LEFT JOIN content.movies mov ON m.id = mov.media_id
  AND m.media_type = 'movie'
  LEFT JOIN content.books bk ON m.id = bk.media_id
  AND m.media_type = 'book'
  LEFT JOIN content.media_images img ON m.id = img.media_id
  AND img.is_primary = true
WHERE
  m.id = $1;

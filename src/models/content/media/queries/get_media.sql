SELECT
  m.id,
  m.title,
  m.media_type,
  m.release_date,
  mov.runtime_minutes,
  bk.total_pages
FROM
  content.media_items m
  LEFT JOIN content.movies mov ON m.id = mov.media_id
  AND m.media_type = 'movie'
  LEFT JOIN content.books bk ON m.id = bk.media_id
  AND m.media_type = 'book'
WHERE
  m.id = $1;

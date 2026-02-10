SELECT
  l.*,
  COALESCE(
    json_agg(json_build_object('media_id', li.media_id)) FILTER (
      WHERE
        li.media_id IS NOT NULL
    ),
    '[]'
  ) AS items
FROM
  profiles.lists l
  LEFT JOIN profiles.lists_items li ON l.id = li.list_id
WHERE
  l.id = $2
  AND (
    l.user_id = $1
    OR l.is_public = true
  )
GROUP BY
  l.id;

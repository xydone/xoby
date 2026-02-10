SELECT 
    media_title,
    media_type,
    status,
    completion_percentage,
    created_at
FROM profiles.progress_summary
WHERE user_id = $1
ORDER BY created_at DESC
LIMIT $2;

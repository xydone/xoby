SELECT * 
FROM profiles.progress_summary
WHERE user_id = $1 AND media_id = $2
ORDER BY created_at DESC;


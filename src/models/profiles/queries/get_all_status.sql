SELECT * FROM (
    SELECT DISTINCT ON (media_id)
        progress_id,
        media_id,
        media_title,
        media_type,
        status,
        progress_value,
        progress_unit,
        completion_percentage,
        created_at
    FROM profiles.progress_summary
    WHERE user_id = $1 
      AND status = $2::profiles.progress_status
    ORDER BY media_id, created_at DESC
) AS latest_by_status
ORDER BY created_at DESC;

WITH user_vars AS (
    SELECT $1::uuid as target_user_id
),
-- streaks
activity_days AS (
    SELECT DISTINCT created_at::date as activity_date
    FROM (
        SELECT created_at FROM profiles.progress WHERE user_id = (SELECT target_user_id FROM user_vars)
        UNION
        SELECT created_at FROM profiles.ratings WHERE user_id = (SELECT target_user_id FROM user_vars)
    ) a
),
streak_groups AS (
    SELECT activity_date, activity_date - (ROW_NUMBER() OVER (ORDER BY activity_date))::int as grp
    FROM activity_days
),
streaks AS (
    SELECT COUNT(*) as len, MAX(activity_date) as last_date 
    FROM streak_groups 
    GROUP BY grp
)

SELECT 
    -- counts
    COUNT(*) FILTER (WHERE m.media_type = 'movie' AND p.status = 'completed') as movies_completed,
    COUNT(*) FILTER (WHERE m.media_type = 'book' AND p.status = 'completed') as books_completed,
    COUNT(*) FILTER (WHERE m.media_type = 'manga' AND p.status = 'completed') as manga_completed,
    COUNT(*) FILTER (WHERE m.media_type = 'comic' AND p.status = 'completed') as comics_completed,

    -- amount of time spent
    COALESCE(ROUND(SUM(mov.runtime_minutes) FILTER (WHERE p.status = 'completed') / 60.0, 2), 0) as hours_watched,
    COALESCE(SUM(b.total_pages) FILTER (WHERE p.status = 'completed'), 0) as pages_read,

    -- ratings
    COALESCE(ROUND(AVG(r.rating_score), 2), 0) as avg_rating,
    COUNT(r.id) FILTER (WHERE r.rating_score = 1) as rating_1,
    COUNT(r.id) FILTER (WHERE r.rating_score = 2) as rating_2,
    COUNT(r.id) FILTER (WHERE r.rating_score = 3) as rating_3,
    COUNT(r.id) FILTER (WHERE r.rating_score = 4) as rating_4,
    COUNT(r.id) FILTER (WHERE r.rating_score = 5) as rating_5,
    COUNT(r.id) FILTER (WHERE r.rating_score = 6) as rating_6,
    COUNT(r.id) FILTER (WHERE r.rating_score = 7) as rating_7,
    COUNT(r.id) FILTER (WHERE r.rating_score = 8) as rating_8,
    COUNT(r.id) FILTER (WHERE r.rating_score = 9) as rating_9,
    COUNT(r.id) FILTER (WHERE r.rating_score = 10) as rating_10,

    -- streaks
    COALESCE((SELECT MAX(len) FROM streaks), 0) as longest_streak,
    COALESCE((SELECT MAX(len) FROM streaks WHERE last_date >= CURRENT_DATE - 1), 0) as current_streak

FROM auth.users u
LEFT JOIN profiles.progress p ON u.id = p.user_id
LEFT JOIN content.media_items m ON p.media_id = m.id
LEFT JOIN content.movies mov ON m.id = mov.media_id
LEFT JOIN content.books b ON m.id = b.media_id
LEFT JOIN profiles.ratings r ON u.id = r.user_id
WHERE u.id = (SELECT target_user_id FROM user_vars)
GROUP BY u.id;

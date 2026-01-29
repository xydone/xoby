SELECT EXISTS (
    SELECT 1
    FROM auth.users
    WHERE role = 'admin'
);

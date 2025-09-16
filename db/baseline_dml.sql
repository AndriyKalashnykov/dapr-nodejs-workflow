-- Insert sample users
INSERT INTO public.users (
    id, created_at, updated_at, email, password, first_name, last_name,
    date_of_birth, country_of_residence, nationality, has_mfa_configured
) VALUES
      (1, NOW(), NOW(), 'john.doe@example.com', 'hashed_password_1', 'John', 'Doe',
       '1980-01-01'::timestamp with time zone, 'USA', 'American', false),
      (2, NOW(), NOW(), 'jane.smith@example.com', 'hashed_password_2', 'Jane', 'Smith',
       '1985-05-15'::timestamp with time zone, 'Canada', 'Canadian', true);

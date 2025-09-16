CREATE TABLE public.users
(
    id                   bigint                   NOT NULL,
    created_at           timestamp with time zone,
    updated_at           timestamp with time zone,
    deleted_at           timestamp with time zone,
    email                text                     NOT NULL,
    password             text                     NOT NULL,
    first_name           text                     NOT NULL,
    last_name            text                     NOT NULL,
    date_of_birth        timestamp with time zone NOT NULL,
    company_id           bigint,
    country_of_residence text                     NOT NULL,
    nationality          text                     NOT NULL,
    otp_secret           text,
    has_mfa_configured   boolean DEFAULT false    NOT NULL,
    password_reset_token text
);

-- Add a primary key to the users table
ALTER TABLE public.users ADD PRIMARY KEY (id);

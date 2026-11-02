\set ON_ERROR_STOP on

\getenv auth_password CENTRIFUGO_AUTH_DB_PASSWORD
\getenv outbox_password CENTRIFUGO_OUTBOX_DB_PASSWORD

\if :{?auth_password}
\else
    \echo 'CENTRIFUGO_AUTH_DB_PASSWORD is required'
    \quit 1
\endif

\if :{?outbox_password}
\else
    \echo 'CENTRIFUGO_OUTBOX_DB_PASSWORD is required'
    \quit 1
\endif

BEGIN;

CREATE SCHEMA IF NOT EXISTS centrifugo AUTHORIZATION CURRENT_USER;

SELECT format(
    'CREATE ROLE centrifugo_auth LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 20 PASSWORD %L',
    :'auth_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'centrifugo_auth')
\gexec

SELECT format(
    'ALTER ROLE centrifugo_auth LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 20 PASSWORD %L',
    :'auth_password'
)
\gexec

SELECT format(
    'CREATE ROLE centrifugo_outbox LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 10 PASSWORD %L',
    :'outbox_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'centrifugo_outbox')
\gexec

SELECT format(
    'ALTER ROLE centrifugo_outbox LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 10 PASSWORD %L',
    :'outbox_password'
)
\gexec

ALTER ROLE centrifugo_auth SET search_path = pg_catalog;
ALTER ROLE centrifugo_outbox SET search_path = pg_catalog;

CREATE OR REPLACE FUNCTION centrifugo.is_uuid(p_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
    SELECT p_value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
$$;

CREATE OR REPLACE FUNCTION centrifugo.channel_is_valid(p_channel text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
    SELECT p_channel IS NOT NULL
       AND length(p_channel) BETWEEN 3 AND 255
       AND (
           p_channel ~ '^public:[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$'
           OR (
               p_channel ~* '^(user|tenant):[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}(:[A-Za-z0-9][A-Za-z0-9_.-]{0,63}){0,4}$'
           )
       );
$$;

CREATE TABLE IF NOT EXISTS centrifugo.outbox (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    message_id uuid NOT NULL DEFAULT gen_random_uuid(),
    channel text NOT NULL,
    tenant_id uuid,
    event text NOT NULL DEFAULT 'message',
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    available_at timestamptz NOT NULL DEFAULT now(),
    attempts integer NOT NULL DEFAULT 0,
    last_error text,
    locked_by text,
    locked_until timestamptz,
    published_at timestamptz,
    CONSTRAINT outbox_message_id_key UNIQUE (message_id),
    CONSTRAINT outbox_channel_check CHECK (centrifugo.channel_is_valid(channel)),
    CONSTRAINT outbox_payload_check CHECK (jsonb_typeof(payload) = 'object'),
    CONSTRAINT outbox_event_check CHECK (event ~ '^[A-Za-z][A-Za-z0-9_.-]{0,63}$'),
    CONSTRAINT outbox_attempts_check CHECK (attempts >= 0)
);

CREATE TABLE IF NOT EXISTS centrifugo.dead_letter (
    message_id uuid PRIMARY KEY,
    original_id bigint NOT NULL,
    channel text NOT NULL,
    tenant_id uuid,
    event text NOT NULL,
    payload jsonb NOT NULL,
    attempts integer NOT NULL,
    last_error text,
    created_at timestamptz NOT NULL,
    failed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS centrifugo.full_payload_tables (
    schema_name text NOT NULL DEFAULT 'public',
    table_name text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    PRIMARY KEY (schema_name, table_name)
);

CREATE INDEX IF NOT EXISTS outbox_pending_idx
    ON centrifugo.outbox (available_at, id)
    WHERE published_at IS NULL;

CREATE INDEX IF NOT EXISTS outbox_partition_idx
    ON centrifugo.outbox (((hashtext(channel) & 2147483647)), id)
    WHERE published_at IS NULL;

CREATE OR REPLACE FUNCTION centrifugo.authorize(p_channel text, p_claims jsonb)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_action text := coalesce(p_claims ->> 'action', '');
    v_namespace text;
    v_channel_id text;
    v_sub text := coalesce(p_claims ->> 'sub', '');
    v_role text := coalesce(p_claims ->> 'role', '');
    v_tenant text;
BEGIN
    IF p_channel IS NULL OR NOT centrifugo.channel_is_valid(p_channel) THEN
        RETURN false;
    END IF;

    IF v_action NOT IN ('subscribe', 'publish') THEN
        RETURN false;
    END IF;

    v_namespace := split_part(p_channel, ':', 1);
    v_channel_id := split_part(p_channel, ':', 2);

    IF v_namespace = 'public' THEN
        IF v_action = 'subscribe' THEN
            RETURN true;
        END IF;

        RETURN v_role = 'authenticated'
            AND v_sub <> ''
            AND centrifugo.is_uuid(v_sub);
    END IF;

    IF v_role <> 'authenticated' OR NOT centrifugo.is_uuid(v_sub) THEN
        RETURN false;
    END IF;

    IF v_namespace = 'user' THEN
        RETURN v_sub = v_channel_id;
    END IF;

    IF v_namespace = 'tenant' THEN
        v_tenant := coalesce(
            p_claims -> 'app_metadata' ->> 'tenant_id',
            p_claims ->> 'tenant_id'
        );

        IF v_tenant IS NULL OR NOT centrifugo.is_uuid(v_tenant) THEN
            RETURN false;
        END IF;

        RETURN lower(v_tenant) = lower(v_channel_id);
    END IF;

    RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION centrifugo.send(
    p_channel text,
    p_payload jsonb DEFAULT '{}'::jsonb,
    p_event text DEFAULT 'message',
    p_tenant_id uuid DEFAULT NULL,
    p_message_id uuid DEFAULT gen_random_uuid(),
    p_available_at timestamptz DEFAULT now()
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_message_id uuid;
    v_tenant_id uuid;
BEGIN
    IF p_channel IS NULL OR NOT centrifugo.channel_is_valid(p_channel) THEN
        RAISE EXCEPTION 'invalid channel' USING ERRCODE = '22023';
    END IF;

    IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
        RAISE EXCEPTION 'payload must be a JSON object' USING ERRCODE = '22023';
    END IF;

    IF p_event IS NULL OR p_event !~ '^[A-Za-z][A-Za-z0-9_.-]{0,63}$' THEN
        RAISE EXCEPTION 'invalid event name' USING ERRCODE = '22023';
    END IF;

    IF split_part(p_channel, ':', 1) = 'tenant' THEN
        v_tenant_id := split_part(p_channel, ':', 2)::uuid;
    END IF;

    IF p_tenant_id IS NOT NULL AND p_tenant_id IS DISTINCT FROM v_tenant_id THEN
        RAISE EXCEPTION 'tenant_id does not match channel' USING ERRCODE = '22023';
    END IF;

    IF p_tenant_id IS NULL THEN
        p_tenant_id := v_tenant_id;
    END IF;

    INSERT INTO centrifugo.outbox (
        message_id,
        channel,
        tenant_id,
        event,
        payload,
        available_at
    )
    VALUES (
        coalesce(p_message_id, gen_random_uuid()),
        p_channel,
        p_tenant_id,
        p_event,
        p_payload,
        coalesce(p_available_at, now())
    )
    ON CONFLICT (message_id) DO NOTHING
    RETURNING message_id INTO v_message_id;

    IF v_message_id IS NULL THEN
        SELECT message_id INTO v_message_id
        FROM centrifugo.outbox
        WHERE message_id = p_message_id;
    END IF;

    IF v_message_id IS NOT NULL THEN
        PERFORM pg_notify('centrifugo_outbox', v_message_id::text);
    END IF;

    RETURN v_message_id;
END;
$$;

CREATE OR REPLACE FUNCTION centrifugo.broadcast_changes(
    p_schema text,
    p_table text,
    p_op text,
    p_row jsonb,
    p_tenant_column text,
    p_old_row jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_event text := lower(p_op);
    v_tenant text;
    v_channel text;
    v_full boolean := false;
    v_payload jsonb;
BEGIN
    IF v_event NOT IN ('insert', 'update', 'delete') THEN
        RAISE EXCEPTION 'unsupported operation' USING ERRCODE = '22023';
    END IF;

    IF p_row IS NULL OR jsonb_typeof(p_row) <> 'object' THEN
        RAISE EXCEPTION 'row must be a JSON object' USING ERRCODE = '22023';
    END IF;

    IF p_schema IS NULL OR p_schema !~ '^[A-Za-z_][A-Za-z0-9_]{0,62}$' THEN
        RAISE EXCEPTION 'invalid schema name' USING ERRCODE = '22023';
    END IF;

    IF p_table IS NULL OR p_table !~ '^[A-Za-z_][A-Za-z0-9_]{0,62}$' THEN
        RAISE EXCEPTION 'invalid table name' USING ERRCODE = '22023';
    END IF;

    IF p_tenant_column IS NULL OR p_tenant_column !~ '^[a-z_][a-z0-9_]{0,62}$' THEN
        RAISE EXCEPTION 'invalid tenant column' USING ERRCODE = '22023';
    END IF;

    v_tenant := p_row ->> p_tenant_column;

    IF v_tenant IS NULL OR NOT centrifugo.is_uuid(v_tenant) THEN
        RAISE EXCEPTION 'tenant column must contain a UUID' USING ERRCODE = '22023';
    END IF;

    v_tenant := lower(v_tenant);
    v_channel := 'tenant:' || v_tenant || ':table:' || p_table;

    IF NOT centrifugo.channel_is_valid(v_channel) THEN
        RAISE EXCEPTION 'generated channel is invalid' USING ERRCODE = '22023';
    END IF;

    SELECT enabled
    INTO v_full
    FROM centrifugo.full_payload_tables
    WHERE schema_name = p_schema AND table_name = p_table;

    v_payload := jsonb_build_object(
        'event', v_event,
        'schema', p_schema,
        'table', p_table,
        'tenant_id', v_tenant,
        'occurred_at', now()
    );

    IF coalesce(v_full, false) THEN
        v_payload := v_payload || jsonb_build_object('record', p_row);

        IF v_event = 'update' AND p_old_row IS NOT NULL THEN
            v_payload := v_payload || jsonb_build_object('old_record', p_old_row);
        END IF;
    END IF;

    RETURN centrifugo.send(v_channel, v_payload, v_event, v_tenant::uuid);
END;
$$;

CREATE OR REPLACE FUNCTION centrifugo.broadcast_changes_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_row jsonb;
    v_old_row jsonb;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_row := to_jsonb(OLD);
    ELSE
        v_row := to_jsonb(NEW);
    END IF;

    IF TG_OP = 'UPDATE' THEN
        v_old_row := to_jsonb(OLD);
    END IF;

    PERFORM centrifugo.broadcast_changes(
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        TG_OP,
        v_row,
        TG_ARGV[0],
        v_old_row
    );

    RETURN NULL;
END;
$$;

-- Revoke legacy or default grants before applying the intended least-privilege set.
REVOKE ALL ON SCHEMA centrifugo FROM PUBLIC, centrifugo_auth, centrifugo_outbox, postgres;
REVOKE ALL ON ALL TABLES IN SCHEMA centrifugo FROM PUBLIC, centrifugo_auth, centrifugo_outbox, postgres;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA centrifugo FROM PUBLIC, centrifugo_auth, centrifugo_outbox, postgres;

GRANT USAGE ON SCHEMA centrifugo TO centrifugo_auth, centrifugo_outbox;
GRANT SELECT, UPDATE, DELETE ON centrifugo.outbox TO centrifugo_outbox;
GRANT SELECT, INSERT ON centrifugo.dead_letter TO centrifugo_outbox;

GRANT EXECUTE ON FUNCTION centrifugo.authorize(text, jsonb) TO centrifugo_auth;
GRANT EXECUTE ON FUNCTION centrifugo.is_uuid(text) TO centrifugo_auth;
GRANT EXECUTE ON FUNCTION centrifugo.channel_is_valid(text) TO centrifugo_auth, centrifugo_outbox;

-- The Supabase migration role owns application tables. It needs only the trigger
-- function and the reviewed full-payload allowlist to opt tables in; it has no
-- explicit outbox/dead-letter privileges and cannot execute send/broadcast.
-- Supabase's postgres role may retain platform-level read-all membership; treat
-- that role as trusted.
GRANT USAGE ON SCHEMA centrifugo TO postgres;
GRANT EXECUTE ON FUNCTION centrifugo.broadcast_changes_trigger() TO postgres;
GRANT SELECT, INSERT, UPDATE ON centrifugo.full_payload_tables TO postgres;

COMMIT;

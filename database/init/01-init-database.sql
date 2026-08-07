-- =============================================================================
-- PostgreSQL container bootstrap.
--
-- Run once by the postgres image's entrypoint, before any application starts,
-- and ONLY when the data directory is empty. Re-running `docker compose up`
-- against an existing volume does not re-execute it; use
-- `docker compose down -v` to force a clean bootstrap.
--
-- Scope is deliberately narrow: this file creates nothing that belongs to the
-- application schema. Tables, indexes, constraints and seed data are owned by
-- Flyway (middleware/src/main/resources/db/migration) so there is exactly one
-- schema authority and one migration history.
--
-- On Amazon RDS this file is not used at all. The database is created by
-- Terraform and the same Flyway migrations run on first rollout.
-- =============================================================================

-- The postgres image has already created the POSTGRES_DB owned by POSTGRES_USER
-- by the time this runs, so connect to it rather than to the default database.
\connect ai_interview

-- -----------------------------------------------------------------------------
-- Timezone. Every timestamp in the schema is timestamptz and every service
-- writes UTC; pinning the database avoids a developer's local timezone changing
-- how `now()` defaults are rendered in psql.
-- -----------------------------------------------------------------------------
ALTER DATABASE ai_interview SET timezone TO 'UTC';

-- -----------------------------------------------------------------------------
-- Statement timeout as a backstop. The services set their own (Hikari and
-- psycopg both pass `statement_timeout`), but a stray psql session should not be
-- able to hold locks indefinitely either. 30s is generous for this workload.
-- -----------------------------------------------------------------------------
ALTER DATABASE ai_interview SET statement_timeout TO '30s';
ALTER DATABASE ai_interview SET idle_in_transaction_session_timeout TO '60s';

-- -----------------------------------------------------------------------------
-- Lock down the public schema.
--
-- PostgreSQL 15+ already revokes CREATE on public from PUBLIC; this is explicit
-- so the local database matches the RDS posture rather than depending on the
-- server's major version.
-- -----------------------------------------------------------------------------
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO PUBLIC;
GRANT ALL ON SCHEMA public TO ai_interview_app;

-- -----------------------------------------------------------------------------
-- Read-only role for troubleshooting.
--
-- Exists so "let me look at production data" never requires the application's
-- own credentials. It has no password here: on RDS it is granted to an IAM
-- database user instead. Default privileges are set so it automatically gains
-- SELECT on tables Flyway creates later.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ai_interview_readonly') THEN
        CREATE ROLE ai_interview_readonly NOLOGIN;
    END IF;
END
$$;

GRANT CONNECT ON DATABASE ai_interview TO ai_interview_readonly;
GRANT USAGE ON SCHEMA public TO ai_interview_readonly;

ALTER DEFAULT PRIVILEGES FOR ROLE ai_interview_app IN SCHEMA public
    GRANT SELECT ON TABLES TO ai_interview_readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE ai_interview_app IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO ai_interview_readonly;

-- -----------------------------------------------------------------------------
-- Confirmation line in the container log, so a failed bootstrap is obvious.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    RAISE NOTICE 'ai_interview bootstrap complete; Flyway owns the application schema';
END
$$;

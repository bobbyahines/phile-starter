-- Deploy tunz:structure/player to pg
-- requires: structure/schema

BEGIN;

  CREATE TABLE tunz.player (
    id uuid UNIQUE NOT NULL DEFAULT uuid_generate_v1(),
    app_tenant_id uuid NOT NULL,
    created_at timestamp NOT NULL DEFAULT current_timestamp,
    updated_at timestamp NOT NULL,
    external_id text,
    first_name text,
    last_name text,
    stage_name text,
    bio_blurb text,
    CONSTRAINT pk_player PRIMARY KEY (id)
  );
  --||--
  ALTER TABLE tunz.player ADD CONSTRAINT fk_player_app_tenant FOREIGN KEY ( app_tenant_id ) REFERENCES auth.app_tenant( id );

  --||--
  CREATE FUNCTION tunz.fn_timestamp_update_player() RETURNS trigger AS $$
  BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
  END; $$ LANGUAGE plpgsql;
  --||--
  CREATE TRIGGER tg_timestamp_update_player
    BEFORE INSERT OR UPDATE ON tunz.player
    FOR EACH ROW
    EXECUTE PROCEDURE tunz.fn_timestamp_update_player();
  --||--


  --||--
  GRANT select ON TABLE tunz.player TO app_user;
  GRANT insert ON TABLE tunz.player TO app_user;
  GRANT update ON TABLE tunz.player TO app_user;
  GRANT delete ON TABLE tunz.player TO app_user;
  --||--
  alter table tunz.player enable row level security;
  --||--
  create policy select_player on tunz.player for select
    using (auth_fn.app_user_has_access(app_tenant_id) = true);

COMMIT;

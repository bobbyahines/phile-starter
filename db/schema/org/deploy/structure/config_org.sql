-- Deploy org:structure/config_org to pg
-- requires: structure/schema

BEGIN;

  CREATE TABLE org.config_org (
    id uuid UNIQUE NOT NULL DEFAULT uuid_generate_v1(),
    key text,
    value text,
    CONSTRAINT pk_config_org PRIMARY KEY (id)
  );

  GRANT select ON TABLE org.config_org TO app_super_admin;
  GRANT insert ON TABLE org.config_org TO app_super_admin;
  GRANT update ON TABLE org.config_org TO app_super_admin;
  GRANT delete ON TABLE org.config_org TO app_super_admin;


COMMIT;

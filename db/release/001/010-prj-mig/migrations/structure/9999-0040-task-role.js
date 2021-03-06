exports.up = function (knex, Promise) {
  return knex.raw(upScript)
}

exports.down = function (knex, Promise) {
  return knex.raw(downScript)
}

const downScript = `
DROP TABLE IF EXISTS prj.task_role CASCADE;
`

const upScript = `
DROP TABLE IF EXISTS prj.task_role CASCADE;
--||--
CREATE TABLE IF NOT EXISTS prj.task_role (
  id uuid UNIQUE NOT NULL DEFAULT uuid_generate_v1(),
  name text,
  CONSTRAINT pk_task_role PRIMARY KEY (id)
);
--||--
GRANT select ON TABLE prj.task_role TO soro_user;
`

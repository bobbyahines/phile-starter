
-- BEGIN: JOBS
--
-- An asynchronous job queue schema for ACID compliant job creation through
-- triggers/functions/etc.
--
-- Worker code: worker.js
--
-- Author: Benjie Gillam <code@benjiegillam.com>
-- License: MIT
-- URL: https://gist.github.com/benjie/839740697f5a1c46ee8da98a1efac218
-- Donations: https://www.paypal.me/benjie

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;

CREATE SCHEMA IF NOT EXISTS app_jobs;

CREATE TABLE app_jobs.job_queue (
  queue_name varchar NOT NULL PRIMARY KEY,
  job_count int DEFAULT 0 NOT NULL,
  locked_at timestamp with time zone,
  locked_by varchar
);
ALTER TABLE app_jobs.job_queue ENABLE ROW LEVEL SECURITY;

CREATE TABLE app_jobs.job (
  id serial PRIMARY KEY,
  queue_name varchar DEFAULT (public.gen_random_uuid())::varchar NOT NULL,
  task_identifier varchar NOT NULL,
  payload json DEFAULT '{}'::json NOT NULL,
  priority int DEFAULT 0 NOT NULL,
  run_at timestamp with time zone DEFAULT now() NOT NULL,
  attempts int DEFAULT 0 NOT NULL,
  last_error varchar,
  created_at timestamp with time zone NOT NULL DEFAULT NOW(),
  updated_at timestamp with time zone NOT NULL DEFAULT NOW()
);
ALTER TABLE app_jobs.job_queue ENABLE ROW LEVEL SECURITY;

CREATE FUNCTION app_jobs.do_notify() RETURNS trigger AS $$
BEGIN
  PERFORM pg_notify(TG_ARGV[0], '');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION app_jobs.update_timestamps() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.created_at = NOW();
    NEW.updated_at = NOW();
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.created_at = OLD.created_at;
    NEW.updated_at = GREATEST(NOW(), OLD.updated_at + INTERVAL '1 millisecond');
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION app_jobs.jobs__decrease_job_queue_count() RETURNS trigger AS $$
BEGIN
  UPDATE app_jobs.job_queue
    SET job_count = job_queue.job_count - 1
    WHERE queue_name = OLD.queue_name
    AND job_queue.job_count > 1;

  IF NOT FOUND THEN
    DELETE FROM app_jobs.job_queue WHERE queue_name = OLD.queue_name;
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION app_jobs.jobs__increase_job_queue_count() RETURNS trigger AS $$
BEGIN
  INSERT INTO app_jobs.job_queue(queue_name, job_count)
    VALUES(NEW.queue_name, 1)
    ON CONFLICT (queue_name) DO UPDATE SET job_count = job_queue.job_count + 1;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER _100_timestamps BEFORE INSERT OR UPDATE ON app_jobs.job FOR EACH ROW EXECUTE PROCEDURE app_jobs.update_timestamps();
CREATE TRIGGER _500_increase_job_queue_count AFTER INSERT ON app_jobs.job FOR EACH ROW EXECUTE PROCEDURE app_jobs.jobs__increase_job_queue_count();
CREATE TRIGGER _500_decrease_job_queue_count BEFORE DELETE ON app_jobs.job FOR EACH ROW EXECUTE PROCEDURE app_jobs.jobs__decrease_job_queue_count();
CREATE TRIGGER _900_notify_worker AFTER INSERT ON app_jobs.job FOR EACH STATEMENT EXECUTE PROCEDURE app_jobs.do_notify('jobs:insert');

CREATE FUNCTION app_jobs.add_job(identifier varchar, payload json) RETURNS app_jobs.job AS $$
  INSERT INTO app_jobs.job(task_identifier, payload) VALUES(identifier, payload) RETURNING *;
$$ LANGUAGE sql;

CREATE FUNCTION app_jobs.add_job(identifier varchar, queue_name varchar, payload json) RETURNS app_jobs.job AS $$
  INSERT INTO app_jobs.job(task_identifier, queue_name, payload) VALUES(identifier, queue_name, payload) RETURNING *;
$$ LANGUAGE sql;

CREATE FUNCTION app_jobs.schedule_job(identifier varchar, queue_name varchar, payload json, run_at timestamptz) RETURNS app_jobs.job AS $$
  INSERT INTO app_jobs.job(task_identifier, queue_name, payload, run_at) VALUES(identifier, queue_name, payload, run_at) RETURNING *;
$$ LANGUAGE sql;

CREATE FUNCTION app_jobs.complete_job(worker_id varchar, job_id int) RETURNS app_jobs.job AS $$
DECLARE
  v_row app_jobs.job;
BEGIN
  DELETE FROM app_jobs.job
    WHERE id = job_id
    RETURNING * INTO v_row;

  UPDATE app_jobs.job_queue
    SET locked_by = null, locked_at = null
    WHERE queue_name = v_row.queue_name AND locked_by = worker_id;

  RETURN v_row;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION app_jobs.fail_job(worker_id varchar, job_id int, error_message varchar) RETURNS app_jobs.job AS $$
DECLARE
  v_row app_jobs.job;
BEGIN
  UPDATE app_jobs.job
    SET
      last_error = error_message,
      run_at = greatest(now(), run_at) + (exp(least(attempts, 10))::text || ' seconds')::interval
    WHERE id = job_id
    RETURNING * INTO v_row;

  UPDATE app_jobs.job_queue
    SET locked_by = null, locked_at = null
    WHERE queue_name = v_row.queue_name AND locked_by = worker_id;

  RETURN v_row;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION app_jobs.get_job(worker_id varchar, identifiers varchar[]) RETURNS app_jobs.job AS $$
DECLARE
  v_job_id int;
  v_queue_name varchar;
  v_default_job_expiry text = (4 * 60 * 60)::text;
  v_default_job_maximum_attempts text = '25';
  v_row app_jobs.job;
BEGIN
  IF worker_id IS NULL OR length(worker_id) < 10 THEN
    RAISE EXCEPTION 'Invalid worker ID';
  END IF;

  SELECT job_queue.queue_name, jobs.id INTO v_queue_name, v_job_id
    FROM app_jobs.job_queue
    INNER JOIN app_jobs.job USING (queue_name)
    WHERE (locked_at IS NULL OR locked_at < (now() - (COALESCE(current_setting('jobs.expiry', true), v_default_job_expiry) || ' seconds')::interval))
    AND run_at <= now()
    AND attempts < COALESCE(current_setting('jobs.maximum_attempts', true), v_default_job_maximum_attempts)::int
    AND (identifiers IS NULL OR task_identifier = any(identifiers))
    ORDER BY priority ASC, run_at ASC, id ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

  IF v_queue_name IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE app_jobs.job_queue
    SET
      locked_by = worker_id,
      locked_at = now()
    WHERE job_queue.queue_name = v_queue_name;

  UPDATE app_jobs.job
    SET attempts = attempts + 1
    WHERE id = v_job_id
    RETURNING * INTO v_row;

  RETURN v_row;
END;
$$ LANGUAGE plpgsql;

-- END: JOBS
view rawjobs.sql hosted with ❤ by GitHub
/*
 * A sample worker for Benjie's Postgres job queue.
 *
 * Requires Node v8.6+ (or Babel)
 *
 * Author: Benjie Gillam <code@benjiegillam.com>
 * License: MIT
 * URL: https://gist.github.com/benjie/839740697f5a1c46ee8da98a1efac218
 * Donations: https://www.paypal.me/benjie
 */

// //////////////////////////////////////////////////////////////////////////////
// //////////////////////////////////////////////////////////////////////////////
// CONFIGURATION

/*
 * tasks: should contain an object, the keys of which are task identifiers and the values of which are job workers.
 * Job workers are asyncronous functions of the form:
 *
 * async function ({ debug, pgPool }, job) {
 *   // worker code here
 * }
 */
const tasks = require("./tasks");

/*
 * idleDelay: This is how long to wait between polling for jobs.
 *
 * Note: this does NOT need to be short, because we use LISTEN/NOTIFY to be
 * notified when new jobs are added - this is just used in the case where
 * LISTEN/NOTIFY fails for whatever reason.
 */
const idleDelay = 15000;

// END OF CONFIGURATION
// //////////////////////////////////////////////////////////////////////////////
// //////////////////////////////////////////////////////////////////////////////

/* eslint-disable no-console */

const pg = require("pg");
const debugFactory = require("debug");

const debug = debugFactory("worker");
debug("Booting worker");

const supportedTaskNames = Object.keys(tasks);
const workerId = `worker-${Math.random()}`;

let doNextTimer = null;

const pgPoolConfig = {
  connectionString: process.env.DATABASE_URL,
};

const requiredDirectly = require.main === module;

const pgPool = requiredDirectly ? new pg.Pool(pgPoolConfig) : null;

function fakePgPool(client) {
  // Only really intended for usage during testing!
  const fakeQuery = (...args) => client.query(...args);
  return {
    connect: () => ({
      query: fakeQuery,
      release: () => {},
    }),
    query: fakeQuery,
  };
}

const doNext = async (client, continuous = true) => {
  if (!continuous && process.env.NODE_ENV !== "test") {
    throw new Error(
      "Continuous should always be true except in a test environment"
    );
  }
  clearTimeout(doNextTimer);
  doNextTimer = null;
  try {
    const {
      rows: [job],
    } = await client.query("SELECT * FROM app_jobs.get_job($1, $2);", [
      workerId,
      supportedTaskNames,
    ]);
    if (!job || !job.id) {
      if (continuous) {
        doNextTimer = setTimeout(() => doNext(client, continuous), idleDelay);
      }
      return null;
    }
    debug(`Found task ${job.id} (${job.task_identifier})`);
    const start = process.hrtime();
    const worker = tasks[job.task_identifier];
    if (!worker) {
      throw new Error("Unsupported task");
    }
    const ctx = {
      debug: debugFactory(`worker:${job.task_identifier}`),
      pgPool: continuous ? pgPool : fakePgPool(client),
      // You can give your workers more context here if you like.
    };
    let err;
    try {
      await worker(ctx, job);
    } catch (error) {
      err = error;
    }
    const durationRaw = process.hrtime(start);
    const duration = ((durationRaw[0] * 1e9 + durationRaw[1]) / 1e6).toFixed(2);
    try {
      if (err) {
        console.error(
          `Failed task ${job.id} (${job.task_identifier}) with error ${err.message} (${duration}ms)`,
          { err, stack: err.stack }
        );
        console.error(err.stack);
        await client.query("SELECT * FROM app_jobs.fail_job($1, $2, $3);", [
          workerId,
          job.id,
          err.message,
        ]);
      } else {
        console.log(
          `Completed task ${job.id} (${job.task_identifier}) with success (${duration}ms)`
        );
        await client.query("SELECT * FROM app_jobs.complete_job($1, $2);", [
          workerId,
          job.id,
        ]);
      }
    } catch (fatalError) {
      const when = err ? `after failure '${err.message}'` : "after success";
      console.error(
        `Failed to release job '${job.id}' ${when}; committing seppuku`
      );
      console.error(fatalError);
      if (continuous) {
        process.exit(1);
      }
    }
    return doNext(client, continuous);
  } catch (err) {
    if (continuous) {
      debug(`ERROR! ${err.message}`);
      doNextTimer = setTimeout(() => doNext(client, continuous), idleDelay);
    } else {
      throw err;
    }
  }
};

function makeNewListener() {
  const listenForChanges = (err, client, release) => {
    if (err) {
      console.error("Error connecting with notify listener", err);
      // Try again in 5 seconds
      setTimeout(makeNewListener, 5000);
      return;
    }
    client.on("notification", _msg => {
      if (doNextTimer) {
        // Must be idle, do something!
        doNext(client);
      }
    });
    client.query('LISTEN "jobs:insert"');
    client.on("error", e => {
      console.error("Error with database notify listener", e);
      release();
      makeNewListener();
    });
    console.log("Worker connected and looking for jobs...");
    doNext(client);
  };
  pgPool.connect(listenForChanges);
}

if (requiredDirectly) {
  if (process.argv.slice(2).includes("--once")) {
    (async function() {
      let exitStatus = 0;
      let client;
      try {
        const client = await pgPool.connect();
        await doNext(client, false);
      } catch (e) {
        console.error(e);
        exitStatus = 1;
      } finally {
        if (client) {
          await client.release();
        }
      }
      pgPool.end();
      process.exit(exitStatus);
    })();
  } else {
    makeNewListener();
  }
} else {
  exports.runAllJobs = client => doNext(client, false);
}
view rawworker.js hosted with ❤ by GitHub
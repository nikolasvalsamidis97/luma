CREATE TABLE licenses (
  id TEXT PRIMARY KEY, key_hash TEXT UNIQUE NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('standard','developer')),
  trial_end INTEGER NOT NULL, seats INTEGER NOT NULL CHECK(seats BETWEEN 1 AND 100),
  revoked INTEGER NOT NULL DEFAULT 0, customer TEXT UNIQUE, subscription TEXT,
  paid_until INTEGER NOT NULL DEFAULT 0, billing_status TEXT,
  checked_at INTEGER NOT NULL DEFAULT 0, checkout TEXT,
  checkout_generation INTEGER NOT NULL DEFAULT 0, label TEXT NOT NULL DEFAULT '',
  billing_lock_token TEXT, billing_lock_until INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE devices (
  device TEXT PRIMARY KEY, token_hash TEXT UNIQUE NOT NULL,
  license_id TEXT NOT NULL REFERENCES licenses(id)
);
CREATE INDEX devices_license ON devices(license_id);
CREATE TABLE trial_devices(device TEXT PRIMARY KEY);
CREATE TABLE events(id TEXT PRIMARY KEY, received INTEGER NOT NULL);
CREATE TABLE limits(bucket TEXT PRIMARY KEY, count INTEGER NOT NULL, expires INTEGER NOT NULL);
CREATE INDEX limits_expiry ON limits(expires);
-- Enforce seats inside SQLite, including races between different Worker isolates.
CREATE TRIGGER device_insert_guard BEFORE INSERT ON devices BEGIN
  SELECT RAISE(ABORT, 'license_revoked') WHERE EXISTS
    (SELECT 1 FROM licenses WHERE id=NEW.license_id AND revoked=1);
  SELECT RAISE(ABORT, 'seat_limit') WHERE
    NOT EXISTS(SELECT 1 FROM devices WHERE device=NEW.device AND license_id=NEW.license_id)
    AND (SELECT count(*) FROM devices WHERE license_id=NEW.license_id) >=
        (SELECT seats FROM licenses WHERE id=NEW.license_id);
END;
CREATE TRIGGER device_update_guard BEFORE UPDATE ON devices BEGIN
  SELECT RAISE(ABORT, 'license_revoked') WHERE EXISTS
    (SELECT 1 FROM licenses WHERE id=NEW.license_id AND revoked=1);
  SELECT RAISE(ABORT, 'seat_limit') WHERE OLD.license_id != NEW.license_id AND
    (SELECT count(*) FROM devices WHERE license_id=NEW.license_id) >=
    (SELECT seats FROM licenses WHERE id=NEW.license_id);
END;

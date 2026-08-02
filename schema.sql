-- A first-party CRM record store on Cloudflare D1.
--
-- Scope: the mutable, relational half of the system. Anonymous events do NOT
-- live here; they go to an append-only analytics stream and arrive as a
-- nightly rollup. Writing per-event rows into this database is the one mistake
-- that will end the free tier for you.
--
-- Every statement is IF NOT EXISTS: this file is applied on top of an existing
-- operational database, not into an empty one.

-- B2B organisations. Optional: a pure B2C base can ignore this table.
CREATE TABLE IF NOT EXISTS crm_accounts (
  id          TEXT PRIMARY KEY,               -- stable external key or acct_<uuid>
  type        TEXT NOT NULL DEFAULT 'other',  -- club|venue|media|partner|other
  name        TEXT,
  website     TEXT,
  country     TEXT,                           -- ISO 3166-1 alpha-2
  region      TEXT,
  city        TEXT,
  status      TEXT NOT NULL DEFAULT 'active', -- active|bounced|unsubscribed|dead
  source      TEXT,                           -- how it entered the base
  enrichment  TEXT,                           -- JSON, refreshed on a schedule
  enriched_at TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT
);

-- People. B2C visitors and B2B contacts share one table: the journey is the
-- same shape, and splitting them means stitching them back together later.
CREATE TABLE IF NOT EXISTS crm_contacts (
  id           TEXT PRIMARY KEY,              -- ct_<uuid>
  email        TEXT,                          -- operational only, never exported to git
  email_hash   TEXT,                          -- sha256(lower(email)): dedup + suppression join
  name         TEXT,
  lang         TEXT,
  country      TEXT,
  account_id   TEXT,                          -- NULL for pure B2C
  role         TEXT,
  lifecycle    TEXT NOT NULL DEFAULT 'lead',  -- anonymous|lead|engaged|customer|churned
  legal_basis  TEXT,                          -- consent|legitimate_interest|contract
  marketing_ok INTEGER NOT NULL DEFAULT 0,    -- the send gate reads this, per country
  source       TEXT,
  score        INTEGER NOT NULL DEFAULT 0,
  first_seen   TEXT,
  last_seen    TEXT,
  created_at   TEXT NOT NULL,
  updated_at   TEXT,
  FOREIGN KEY (account_id) REFERENCES crm_accounts(id)
);

-- The stitch. One row turns months of anonymous history into a known person.
CREATE TABLE IF NOT EXISTS crm_identities (
  anon_id    TEXT NOT NULL,
  contact_id TEXT NOT NULL,
  first_seen TEXT NOT NULL,
  source     TEXT,                            -- link|form|subscribe|vote
  PRIMARY KEY (anon_id, contact_id)
);

-- Append-only. Never UPDATE a row here; a withdrawal is a new row with
-- granted = 0. The history is the point.
CREATE TABLE IF NOT EXISTS crm_consents (
  id          TEXT PRIMARY KEY,
  contact_id  TEXT NOT NULL,
  purpose     TEXT NOT NULL,                  -- analytics|marketing_email|...
  granted     INTEGER NOT NULL,               -- 1 grant, 0 withdraw
  legal_basis TEXT,
  source      TEXT,                           -- form URL, import, preference centre
  ip_hash     TEXT,                           -- salted hash, never a raw address
  ts          TEXT NOT NULL
);

-- Keyed by hash, not by contact_id, so a right-to-erasure deletion of the
-- contact leaves the suppression standing.
CREATE TABLE IF NOT EXISTS crm_suppression (
  email_hash TEXT PRIMARY KEY,
  reason     TEXT NOT NULL,                   -- unsubscribe|bounce|complaint|manual
  channel    TEXT DEFAULT 'email',
  ts         TEXT NOT NULL
);

-- What we sent and what came back.
CREATE TABLE IF NOT EXISTS crm_touches (
  id           TEXT PRIMARY KEY,
  contact_id   TEXT NOT NULL,
  account_id   TEXT,
  campaign     TEXT,
  touch_number INTEGER,
  channel      TEXT NOT NULL DEFAULT 'email',
  status       TEXT NOT NULL DEFAULT 'sent',  -- sent|clicked|bounced|replied
  sent_at      TEXT NOT NULL,
  meta         TEXT                           -- JSON
);

-- Written by the nightly rollup from the analytics stream. One row per device,
-- not per event: this is the whole reason the free tier holds.
CREATE TABLE IF NOT EXISTS crm_anon_rollup (
  anon_id    TEXT PRIMARY KEY,
  first_seen TEXT,
  last_seen  TEXT,
  events     INTEGER NOT NULL DEFAULT 0,
  page_views INTEGER NOT NULL DEFAULT 0,
  downloads  INTEGER NOT NULL DEFAULT 0,      -- high-intent actions
  clicks     INTEGER NOT NULL DEFAULT 0,      -- arrivals from tracked links
  updated_at TEXT
);

-- Indexes.
--
-- Not optional, and not a later optimisation. Without them a 10,000-row table
-- served 6.5 to 8 million row reads per day against a 5 million daily
-- allowance, because every admin query scanned everything. Add an index for
-- each query you actually run, and watch rows read rather than database size.

CREATE INDEX IF NOT EXISTS idx_contacts_hash      ON crm_contacts   (email_hash);
CREATE INDEX IF NOT EXISTS idx_contacts_account   ON crm_contacts   (account_id);
CREATE INDEX IF NOT EXISTS idx_contacts_lifecycle ON crm_contacts   (lifecycle, last_seen);
CREATE INDEX IF NOT EXISTS idx_identities_contact ON crm_identities (contact_id);
CREATE INDEX IF NOT EXISTS idx_consents_contact   ON crm_consents   (contact_id, ts);
CREATE INDEX IF NOT EXISTS idx_touches_contact    ON crm_touches    (contact_id, sent_at);
CREATE INDEX IF NOT EXISTS idx_touches_campaign   ON crm_touches    (campaign, status);
CREATE INDEX IF NOT EXISTS idx_accounts_country   ON crm_accounts   (country, status);
CREATE INDEX IF NOT EXISTS idx_rollup_last_seen   ON crm_anon_rollup(last_seen);

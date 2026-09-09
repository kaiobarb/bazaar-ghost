-- Operational ownership is local to this deployment. Never seed or import it.
CREATE TABLE platform_ingestion_dispatch (
 id INTEGER PRIMARY KEY CHECK(id=1),
 ticket_id TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN('idle','queued','running')),
 lease_expires_at TEXT,
 next_attempt_at TEXT NOT NULL,
 run_id TEXT,
 run_attempt TEXT,
 delivery_failures INTEGER NOT NULL DEFAULT 0 CHECK(delivery_failures BETWEEN 0 AND 10),
 last_attempt_at TEXT NOT NULL,
 started_at TEXT,
 finished_at TEXT,
 outcome TEXT CHECK(outcome IN('accepted','delivery_unconfirmed','success','failure','cancelled')),
 CHECK(state='idle' OR lease_expires_at IS NOT NULL),
 CHECK(state<>'running' OR (run_id IS NOT NULL AND run_attempt IS NOT NULL))
);

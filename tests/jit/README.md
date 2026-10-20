# Just-in-time access flow test

`flow_test.py` runs the self-service flow end to end against real targets: request (instant and with
approval), duplicate requests, extension (lengthens the same access, counted from its end), End now,
rejection and automatic close notes, and a PostgreSQL login whose expiry follows an extension.

Run it in a core container connected to a throwaway database (never the live one) on a Docker network
with a Debian SSH host `flowhost` (env `ROOT_PASSWORD`) and a PostgreSQL server `flowpg`
(env `TARGET_PG_PASSWORD`).

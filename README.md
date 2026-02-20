# Postgres-RDS-To-OCI-Solution-Guide-Scripts
# Amazon RDS PostgreSQL to OCI PostgreSQL Zero-Downtime Migration

**Author:** Shadab Mohammad, Master Principal Cloud Architect 
**Version:** 1.0  
**Date:** 2026-02-20  
**Audience:** Cloud Architects, Database Engineers, Migration Program Managers

---

## 1. Executive Summary

This guide describes an end-to-end migration blueprint for lifting and shifting
Amazon RDS or Aurora PostgreSQL workloads into Oracle Cloud Infrastructure (OCI)
PostgreSQL with zero or near-zero downtime. It combines:

1. An automated discovery script (`rds_db_instances_details.sh`) to inventory
   PostgreSQL-compatible instances across every AWS Region, highlight Multi-AZ
   gaps, and flag storage saturation risks.
2. A proven Oracle GoldenGate (GG) pattern for schema instantiation, high-speed
   initial load, and ongoing change data capture (CDC) replication.
3. An alternative pglogical-based approach for customers who prefer an
   in-database logical replication stack over GoldenGate.

The document is structured as a consulting engagement playbook that you can
re-use for assessments, pilot migrations, and scaled production cutovers.

---

## 2. Goals, Deliverables, Success Criteria, Constraints

| Area                 | Details                                                                                                                                                                                                                              |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Goals**            | Inventory source estates, prepare connectivity, migrate schema & data, enable continuous replication, execute controlled cutover.                                                                                                    |
| **Deliverables**     | Discovery CSV, migration readiness checklist, GoldenGate deployment (extract/replicat pairs), validated OCI PostgreSQL target, runbook updates, alternate pglogical plan.                                                            |
| **Success Criteria** | Zero data loss, <60s read-only window for app cutover, source & target row-count reconciliation within ±0.1%, OCI PostgreSQL meets performance KPIs, documented rollback plan.                                                       |
| **Constraints**      | Source remains write-active until cutover, network path must sustain peak redo volume, AWS IAM permissions required for discovery, OCI tenancy must allow GoldenGate & PostgreSQL resources, no modification of core business logic. |

---

## 3. Reference Architecture

```text
```

- **Connectivity:** Use FastConnect + VPN or Site-to-Site VPN with redundant
  tunnels. Latency should remain <30 ms where possible.
- **Landing Zone:** Deploy an OCI Compute bastion in the same subnet as
  GoldenGate to host PostgreSQL client utilities and act as the migration
  control plane.
- **Security:** Open TCP/5432 bi-directionally between GG deployment and both
  databases. Restrict SSH and GG consoles to jump hosts/VPN.

---

## 4. Phase Breakdown

| Phase                     | Objective                                                                            | Outputs                                                     |
| ------------------------- | ------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| 0. Discovery & Assessment | Enumerate RDS/Aurora PostgreSQL assets, risk-rank them, and size network throughput. | `rds_db_instances_details.csv`, remediation recommendations |
| 1. Pre-Migration Prep     | Configure parameter groups, IAM, networking, OCI targets, and validation harness.    | Ready-for-migration checklist                               |
| 2. Baseline Copy          | Export schema/data and import into OCI to create an initial landing dataset.         | Schema parity validated                                     |
| 3. GoldenGate CDC         | Establish GG deployment, run initial load extract/replicat, enable CDC, monitor lag. | Trails, LSN checkpoints, health dashboards                  |
| 4. Validation & Cutover   | Reconcile row counts, execute app switch, post-migration tuning.                     | Sign-off, rollback plan                                     |
| Alt. Pglogical            | (Optional) Use pglogical extension for initial load + CDC.                           | pglogical subscription                                      |

---

## 5. Phase 0 – Automated Discovery

### 5.1 Script Overview

File: `rds_db_instances_details.sh`

- Enumerates all AWS Regions via `aws ec2 describe-regions` and iterates each
  RDS instance.
- Captures engine/version, storage allocation/max, Multi-AZ flag,
  backup/maintenance windows, IAM auth, encryption, and endpoint.
- Flags **AttentionStorage** when `MaxAllocatedStorage` is `None` or remaining
  capacity drops below `nStorageAllocationWatermarkPctg` (25% by default).
- Flags **AttentionMultiAZ** when `MultiAZ=False` to highlight HA remediation
  before migration.
- Emits console summary plus CSV (`rds_db_instances_details.csv`) consumable by
  spreadsheets or analytics tooling.

### 5.2 Prerequisites

| Requirement     | Description                                                                                                 |
| --------------- | ----------------------------------------------------------------------------------------------------------- |
| AWS CLI v2      | Configure with least-privileged IAM profile capable of `rds:DescribeDBInstances` and `ec2:DescribeRegions`. |
| jq / bash       | Provided by default on most Linux/macOS control hosts.                                                      |
| Output Location | Script writes to the working directory; ensure write permissions.                                           |

### 5.3 Execution

```bash
chmod +x rds_db_instances_details.sh
./rds_db_instances_details.sh > discovery.log 2>&1
```

Review `rds_db_instances_details.csv` to:

1. Filter to `Engine in (postgres, aurora-postgresql)`.
2. Highlight instances lacking Multi-AZ.
3. Compute replication sizing: `MaxAllocatedStorage × churn %` to estimate redo
   volume for GoldenGate throughput planning.
4. Capture endpoints and preferred windows for scheduling the initial load.

Document remediation tasks (e.g., enable Multi-AZ, expand storage) before
migration kick-off.

---

## 6. Phase 1 – Pre-Migration Preparation

1. **Parameter Group:** Create dedicated RDS parameter group with
   `rds.logical_replication = 1`. For production, additionally tune WAL
   retention and checkpoint parameters via
   `aws rds describe-db-parameters --db-parameter-group-name <group>`.
2. **Privileges:** Ensure a PostgreSQL user with `REPLICATION` privilege,
   `SELECT` on all schemas, and ability to create logical replication slots.
3. **Networking:**
   - Configure FastConnect or Site-to-Site VPN with redundant IPSec tunnels.
   - Update AWS security groups and OCI security lists to allow TCP/5432 and
     GoldenGate admin ports.
4. **OCI Target Build:**
   - Provision OCI Database with PostgreSQL (matching major version, e.g.,
     14.9).
   - Deploy GoldenGate service in the same region/VCN as the target.
   - Create an OCI Compute instance (bastion) with PostgreSQL client (`psql`,
     `pg_dump`, `pg_restore`).
5. **Operational Readiness:**
   - Define monitoring via OCI Observability, AWS CloudWatch, and GoldenGate
     metrics.
   - Prepare change tickets, communication plans, and maintenance windows
     aligned with business stakeholders.

Output: Signed checklist confirming all prerequisites satisfied.

---

## 7. Phase 2 – Baseline Schema & Data Copy

### 7.1 Sample Workflow (DVDRental example)

1. Download and load sample data if required:

   ```bash
   pg_restore -h <bastion-ip> -U postgres -d dvdrental dvdrental.tar
   ```

2. Validate connectivity to source:

   ```bash
   psql -h <rds-endpoint> -U postgres -d dvdrental -c "\dt"
   ```

### 7.2 Metadata-Only Export

```bash
pg_dump \
  -h <rds-endpoint> \
  -U postgres \
  -d dvdrental \
  -Fd -b -v -s -j 4 \
  --file=dvdrental_schema
```

### 7.3 Import into OCI PostgreSQL

```bash
pg_restore \
  -h <oci-postgres-endpoint> \
  -U postgres \
  -d dvdrental \
  -v -j 4 \
  dvdrental_schema
```

### 7.4 Data Validation

- Run `pg_dump --schema-only` both sides and diff.
- Check role mappings, extensions, and tablespace references.
- Document any incompatibilities (e.g., unsupported extensions in OCI
  PostgreSQL).

Outcome: OCI PostgreSQL mirrors source schema and is ready for GoldenGate
initial load.

---

## 8. Phase 3 – Oracle GoldenGate Implementation

### 8.1 Deployment Checklist

1. Provision GoldenGate deployment (latest version) in OCI.
2. Create admin user with MFA and secure password vault.
3. Register **Source Connection** (AWS RDS endpoint) and **Target Connection**
   (OCI PostgreSQL).
4. Validate connectivity test cases and TLS certificates.

### 8.2 Enable Supplemental Logging

- Add trandata for the required tables/schemas from the GG console to ensure
  primary keys or unique identifiers exist for CDC.

### 8.3 Initial Load Extract

| Step | Action                                                  | Notes                                 |
| ---- | ------------------------------------------------------- | ------------------------------------- |
| 1    | Configure Initial Load Extract in GG for source schema. | Use `INITIALLOADOPTIONS USESNAPSHOT`. |
| 2    | Capture resulting LSN from report file.                 | e.g., `LSN 5/5C000148`.               |
| 3    | Store LSN in runbook for seeding CDC Extract.           | Required to guarantee continuity.     |

### 8.4 CDC Extract

1. Create CDC Extract referencing the same source DB and specify
   `Start With LSN <captured>`.
2. Monitor report file to confirm replication slot status:
   `OGG-25376 ... plugin test_decoding ... restart LSN ...`.
3. Generate transactional workload on RDS to validate capture. Example:

```sql
SELECT add_random_orders(20000);
```

### 8.5 Initial Load Replicat

- Configure Replicat in OCI pointing to target database using the trail from
  Initial Load Extract.
- Add GG checkpoint table to OCI Postgres (`ggschema.chkpt`).
- Monitor statistics until counts match (e.g., `orders=30000`).
- After completing the bulk load, stop the Initial Load Replicat.

### 8.6 CDC Replicat

- Create CDC Replicat bound to the CDC trail.
- Validate that row counts converge (e.g., `orders=50000`).
- Track latency metrics; ensure they remain <5 seconds under peak load.

### 8.7 Operations & Monitoring

| Metric             | Tooling                             | Threshold                    |
| ------------------ | ----------------------------------- | ---------------------------- |
| Extract Lag        | GoldenGate metrics / OCI Monitoring | < 60 seconds                 |
| Replicat Lag       | GoldenGate                          | < 30 seconds                 |
| Slot Restart LSN   | `psql` / `pg_replication_slots`     | Should advance continuously  |
| Network Throughput | VCN Flow Logs, CloudWatch           | At least 2× peak redo volume |

### 8.8 Security & Compliance

- Rotate credentials regularly; integrate with OCI Vault.
- Enable encryption in flight (TLS) and at rest (OCI PostgreSQL encrypted
  storage by default).
- Retain GG trail files per compliance policy; export to Object Storage if
  long-term retention is required.

---

## 9. Phase 4 – Validation, Cutover, and Post-Migration

1. **Row Count Reconciliation:** Compare `COUNT(*)` per table or use checksum
   queries. Automate via scripts.
2. **Application Read-Only Window:** Announce switchover, pause writes, allow
   CDC to drain, then point application connection strings to OCI PostgreSQL.
3. **Functional Verification:** Run smoke/regression tests, ensure sequences,
   jobs, and extensions behave as expected.
4. **Performance Tuning:** Execute `VACUUM ANALYZE`, rebuild statistics, review
   query plans, and adjust `work_mem`, `shared_buffers`, etc.
5. **Post-Migration Cleanup:**
   - Decommission GoldenGate after observation period.
   - Remove logical replication slot from RDS.
   - Archive discovery reports and sign-off documentation.
6. **Rollback Plan:** Maintain ability to revert DNS/app endpoints to AWS if
   validation fails within the agreed window.

---

## 10. Alternate Approach: pglogical (Initial Load + CDC) *BETA*

For workloads that prefer native logical replication without GoldenGate
licensing, pglogical offers an integrated alternative.

### 10.1 Considerations

| Aspect                | GoldenGate                                  | pglogical                                   |
| --------------------- | ------------------------------------------- | ------------------------------------------- |
| Management            | Managed OCI service with GUI and monitoring | SQL-driven configuration, manual monitoring |
| Heterogeneous Support | Broad (multi-engine)                        | PostgreSQL-to-PostgreSQL only               |
| Conflict Handling     | Advanced resolution policies                | Basic last-write-wins                       |
| Licensing             | OCI GG subscription                         | OSS (extension)                             |

### 10.2 Implementation Steps

- **Enable pglogical extension** on both source RDS (supported versions) and
  OCI PostgreSQL via parameter group / `shared_preload_libraries`.
- **Initial Schema/Data Copy:** Use the same `pg_dump/pg_restore` method
  described in Phase 2.
- **Create Provider (Source):**

```sql
CREATE EXTENSION IF NOT EXISTS pglogical;
SELECT pglogical.create_node(
  node_name := 'rds_provider',
  dsn := 'host=<rds-endpoint> port=5432 dbname=dvdrental user=replicator password=***'
);
SELECT pglogical.create_replication_set(
  'default',
  include_insert := true,
  include_update := true,
  include_delete := true
);
SELECT pglogical.replication_set_add_all_tables(
  'default',
  schema_names := ARRAY['public']
);
```

- **Create Subscriber (OCI Target):**

```sql
CREATE EXTENSION IF NOT EXISTS pglogical;
SELECT pglogical.create_node(
  node_name := 'oci_subscriber',
  dsn := 'host=<oci-endpoint> port=5432 dbname=dvdrental user=replicator password=***'
);
SELECT pglogical.create_subscription(
  subscription_name := 'rds_to_oci',
  provider_dsn := 'host=<rds-endpoint> port=5432 dbname=dvdrental user=replicator password=***',
  replication_sets := ARRAY['default'],
  synchronize_structure := false,
  synchronize_data := true
);
```

- **Monitor Lag:** Query `pglogical.show_subscription_status()` or
  `pg_replication_slots`.
- **Cutover:** Similar to GoldenGate—pause writes, ensure `pending_changes=0`,
  switch application endpoints.

### 10.3 When to Use

- Homogeneous PostgreSQL migrations where GoldenGate is unavailable.
- Smaller estates needing a lightweight CDC mechanism.
- Teams comfortable managing SQL-level replication without GUI.

---

## 11. Risk Register & Mitigations

| Risk                            | Description                                                            | Mitigation                                                                          |
| ------------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Insufficient bandwidth          | Initial load or CDC trails fall behind due to limited throughput.      | Pre-stage data off-hours, compress dumps, upgrade FastConnect bandwidth.            |
| Parameter drift                 | RDS parameter group not aligned with logical replication requirements. | Standardize parameter templates, automated validation before deployment.            |
| Schema changes during migration | DDL executed on source while initial load is running.                  | Enforce change freeze or replicate DDL through GoldenGate with DDL capture enabled. |
| Large objects                   | BLOB/CLOB transfer may suffer latency.                                 | Enable `--blobs` in pg_dump, test LOB throughput, chunk migrations if needed.       |
| Cutover overruns                | Application switchover exceeds window.                                 | Rehearse cutover in staging, pre-validate runbooks, maintain rollback plan.         |

---

## 12. Validation Checklist

- [ ] Discovery CSV reviewed, remediation actions tracked.
- [ ] Parameter groups applied and reboot completed on RDS/Aurora.
- [ ] OCI PostgreSQL sized per performance requirements and connectivity tested.
- [ ] pg_dump / pg_restore logs archived, schema diff clean.
- [ ] GoldenGate extract/replicat pairs healthy, lag within SLA.
- [ ] Row-count & checksum parity recorded.
- [ ] Application smoke tests executed post-cutover.
- [ ] Post-migration tasks (password rotation, VACUUM ANALYZE) completed.

---

## 13. Appendix

### 13.1 Key Commands

| Purpose                 | Command                                                            |
| ----------------------- | ------------------------------------------------------------------ |
| Describe RDS parameters | `aws rds describe-db-parameters --db-parameter-group-name <group>` |
| View replication slots  | `SELECT * FROM pg_replication_slots;`                              |
| Check GG CDC lag        | GoldenGate Deployment Console → Metrics                            |

### 13.2 References

1. [OCI GoldenGate Documentation](https://docs.oracle.com/en/cloud/paas/goldengate-service/)
2. [Prepare PostgreSQL for GoldenGate](https://docs.oracle.com/en/middleware/goldengate/core/21.3/coredoc/prepare-postgresql.html)
3. [OCI GoldenGate Initial Load Guide](https://docs.oracle.com/en/middleware/goldengate/core/21.3/gghdb/add-initial-load-extract-postgresql.html)
4. [pglogical Project](https://www.2ndquadrant.com/en/resources/pglogical/)
5. [OCI Database with PostgreSQL](https://docs.oracle.com/en/engineered-systems/oci-database-postgresql/)

---

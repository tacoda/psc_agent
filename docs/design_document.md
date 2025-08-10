# Technical Design Document

## Description of the Problem

Lending teams at credit unions often face delays when attempting to collect proof of income
documentation, such as pay stubs, from applicants after conditional approval. These delays
introduce friction in the lending workflow, frustrate both staff and applicants, and increase time-
to-funding.

Shastic customers need an automated, fault-tolerant system that detects when a loan
application is approved and flagged for income verification, then triggers a workflow to collect
the document, store it securely, and update the third-party Loan Origination System (LOS) via
RPA. The workflow must notify a human agent when automated collection fails.

## Background

This workflow supports a key job-to-be-done for lending managers: “Verify that all required
documentation has been collected so the loan can move to funding.” Based on Shastic’s
Customer Interview Analysis, this job is a common bottleneck and often leads to manual follow-
up, status ambiguity, or delays in LOS updates.

The “Pay Stub Collector” agent will operate as part of Shastic’s Mago platform and must comply
with SOC 2 controls while integrating with existing agent orchestration, logging, and notification
infrastructure. It must be resilient under scale, able to retry gracefully, and transparent to both
internal teams and external auditors.

## Solution Requirements (Goals)

- Detect when a loan record is approved with income documentation required
- Trigger the “Pay Stub Collector” agent within seconds
- Request and retrieve the document from the applicant via API or secure communication
- Upload the document via RPA into the LOS and verify success
- Retry up to 3 times on failure with exponential backoff
- Notify a human agent (e.g., lending officer) when automation fails or completes
successfully
- Maintain an audit log of each step in the agent lifecycle
- Scale to handle 10,000 loan records per job trigger across 500,000 jobs per day

## Glossary

## Out of Scope (Non-goals)

- Design of other agent workflows (e.g., Document Type Verifier)
- Creation of UI components for document collection or status tracking
- Development of a new RPA worker from scratch

## Solution

## Entity Relationship Diagram

```mermaid
erDiagram
    ORGANIZATIONS ||--o{ USERS : has
    ORGANIZATIONS ||--o{ LOAN_APPLICATIONS : owns
    ORGANIZATIONS ||--o{ JOBS : owns
    ORGANIZATIONS ||--o{ EVENTS : scopes
    ORGANIZATIONS ||--o{ NOTIFICATIONS : scopes
    ORGANIZATIONS ||--o{ EXECUTION_QUEUE : scopes
    ORGANIZATIONS ||--o{ ROUTING_RULES : config

    USERS ||--o{ JOBS : triggered_by
    USERS ||--o{ EVENTS : actor
    USERS ||--o{ NOTIFICATIONS : recipient

    JOBS ||--o{ JOB_RECORDS : contains
    LOAN_APPLICATIONS ||--o{ JOB_RECORDS : targets
    LOAN_APPLICATIONS ||--o{ DOCUMENTS : has

    JOB_RECORDS ||--o{ AGENT_RUNS : attempts
    JOB_RECORDS ||--o{ RPA_UPLOADS : uploads
    JOB_RECORDS ||--o{ EVENTS : emits
    JOB_RECORDS ||--o{ NOTIFICATIONS : notifies
    JOB_RECORDS ||--o{ EXECUTION_QUEUE : enqueues

    EXECUTION_QUEUE ||--o| DEAD_LETTER_QUEUE : deadletters
    ROUTING_RULES ||--o{ JOBS : governs

    ORGANIZATIONS {
      bigint organization_id PK
      string name
      string status
      datetime created_at
    }

    USERS {
      bigint user_id PK
      bigint organization_id FK
      string email
      string name
      string role
      string status
      datetime created_at
    }

    LOAN_APPLICATIONS {
      bigint loan_id PK
      bigint organization_id FK
      string applicant_id
      string los_external_id
      string status
      boolean income_doc_required
      datetime approved_at
      datetime created_at
      datetime updated_at
    }

    JOBS {
      bigint job_id PK
      bigint organization_id FK
      string agent_type
      string trigger_source
      bigint triggered_by_user_id FK
      string status
      int total_records
      datetime created_at
      datetime started_at
      datetime completed_at
    }

    JOB_RECORDS {
      bigint job_record_id PK
      bigint job_id FK
      bigint loan_id FK
      string state
      int retry_count
      datetime next_attempt_at
      string last_error_code
      string last_error_msg
      datetime created_at
      datetime updated_at
    }

    AGENT_RUNS {
      bigint agent_run_id PK
      bigint job_record_id FK
      string phase
      string status
      datetime started_at
      datetime ended_at
      string worker_id
      string idempotency_key
    }

    DOCUMENTS {
      bigint document_id PK
      bigint loan_id FK
      string type
      string status
      string sha256
      bigint size_bytes
      string storage_url
      string kms_key_id
      datetime created_at
    }

    RPA_UPLOADS {
      bigint rpa_upload_id PK
      bigint job_record_id FK
      bigint document_id FK
      string los_session_id
      string status
      int attempt
      datetime started_at
      datetime ended_at
      string error_code
      string error_msg
    }

    EVENTS {
      bigint event_id PK
      bigint organization_id FK
      bigint user_id FK
      bigint job_id FK
      bigint job_record_id FK
      string type
      string phase
      string severity
      string message
      datetime ts
      string trace_id
    }

    NOTIFICATIONS {
      bigint notification_id PK
      bigint organization_id FK
      bigint job_record_id FK
      string channel
      bigint recipient_user_id FK
      string type
      string status
      datetime sent_at
      string error_msg
    }

    EXECUTION_QUEUE {
      bigint queue_msg_id PK
      bigint organization_id FK
      bigint job_record_id FK
      string payload_ref
      datetime visible_at
      int attempts
      int max_attempts
      string status
    }

    DEAD_LETTER_QUEUE {
      bigint dlq_msg_id PK
      bigint orig_queue_msg_id FK
      bigint job_record_id FK
      string reason_code
      string reason_detail
      datetime moved_at
      datetime redriven_at
    }

    ROUTING_RULES {
      bigint rule_id PK
      bigint organization_id FK
      boolean enabled
      string criteria_json
      datetime updated_at
      string checksum
      boolean canary
    }
```

## Sequence Diagram

## Data Models and Data Relationships

## Security Considerations

## Cost Awareness

## Risks and Open Issues

## Alternative Solutions Considered

## Work Required

## High-Level Test Plan

## References

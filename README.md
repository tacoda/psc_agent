# Pay Stub Collector Agent

## Technical Design Document

A [technical design document](docs/technical_design_document.md) is included in the documentation of this repository.

## Setup

### Prerequisites

- PostgreSQL
- Ruby
- Bundler

```sh
bundle install
bin/rails db:migrate:queue
bin/rails db:migrate
bin/rails db:seed
bin/rails assets:precompile
bin/rails server
```

## Usage

The job dashboard is located at `localhost:3000/jobs`

The audit trail is located at `localhost:3000/audits`

### Triggering Workflows with curl

The following curl examples demonstrate how to trigger pay stub collection workflows. Make sure to use the correct API key (configured in Rails credentials).

#### Webhook Trigger (Automated Loan Approval)

Trigger pay stub collection when a loan is approved with income documentation required:

```bash
# Basic webhook trigger
curl -X POST http://localhost:3000/loan_approvals/webhook \
  -H "Content-Type: application/json" \
  -d '{
    "organization_id": 1,
    "loan_application": {
      "los_external_id": "LOS-12345",
      "applicant_id": "ACC-TEST-001",
      "status": "approved",
      "income_doc_required": true,
      "approved_at": "2025-01-15T10:30:00Z",
      "notes": "Loan conditionally approved - pay stub required for final verification"
    }
  }'

# Webhook trigger based on notes (even without income_doc_required flag)
curl -X POST http://localhost:3000/loan_approvals/webhook \
  -H "Content-Type: application/json" \
  -d '{
    "organization_id": 1,
    "loan_application": {
      "los_external_id": "LOS-67890",
      "applicant_id": "ACC-TEST-002",
      "status": "approved",
      "income_doc_required": false,
      "approved_at": "2025-01-15T10:30:00Z",
      "notes": "Approved with condition - pay stub required before funding"
    }
  }'
```

#### Manual Trigger (Lending Officer Initiated)

Manually trigger pay stub collection for a specific loan application:

```bash
curl -X POST http://localhost:3000/loan_approvals/manual_trigger \
  -H "Content-Type: application/json" \
  -d '{
    "loan_application_id": 1,
    "user_id": 2
  }'
```

#### Batch Processing

Trigger batch processing for multiple loan applications:

```bash
# Batch webhook (multiple loans from LOS)
curl -X POST http://localhost:3000/loan_approvals/batch_webhook \
  -H "Content-Type: application/json" \
  -d '{
    "organization_id": 1,
    "loan_applications": [
      {
        "los_external_id": "LOS-BATCH-001",
        "applicant_id": "ACC-BATCH-001",
        "status": "approved",
        "income_doc_required": true,
        "approved_at": "2025-01-15T10:30:00Z"
      },
      {
        "los_external_id": "LOS-BATCH-002",
        "applicant_id": "ACC-BATCH-002",
        "status": "approved",
        "income_doc_required": true,
        "approved_at": "2025-01-15T10:35:00Z"
      }
    ]
  }'

# Manual batch trigger
curl -X POST http://localhost:3000/loan_approvals/manual_batch_trigger \
  -H "Content-Type: application/json" \
  -d '{
    "loan_application_ids": [1, 2, 3],
    "user_id": 2
  }'
```

### Monitoring and Management APIs

#### RPA Upload Status

```bash
# Get overall RPA upload status
curl -X GET "http://localhost:3000/rpa_uploads/status?organization_id=1"

# Get specific job record status
curl -X GET http://localhost:3000/rpa_uploads/job_record/1

# Get stuck uploads
curl -X GET "http://localhost:3000/rpa_uploads/stuck?threshold_minutes=30"

# Get metrics for monitoring
curl -X GET http://localhost:3000/rpa_uploads/metrics
```

#### RPA Upload Management

```bash
# Escalate stuck uploads to human intervention
curl -X POST "http://localhost:3000/rpa_uploads/escalate_stuck?threshold_minutes=30"

# Retry failed uploads
curl -X POST http://localhost:3000/rpa_uploads/retry_failed \
  -H "Content-Type: application/json" \
  -d '{
    "job_record_ids": [1, 2, 3],
    "reset_retry_count": false
  }'
```

#### Batch Job Monitoring

```bash
# List all batch jobs
curl -X GET http://localhost:3000/batch_jobs

# Get running batch jobs
curl -X GET http://localhost:3000/batch_jobs/running

# Get batch job analytics
curl -X GET http://localhost:3000/batch_jobs/analytics

# Get specific batch job status
curl -X GET http://localhost:3000/batch_jobs/1/status

# Cancel a running batch job
curl -X POST http://localhost:3000/batch_jobs/1/cancel

# Retry failed records in a batch job
curl -X POST http://localhost:3000/batch_jobs/1/retry_failed
```

### Expected Responses

Successful webhook trigger:
```json
{
  "status": "success",
  "message": "Pay stub collection agent triggered for loan LOS-12345",
  "job_id": 42,
  "job_record_id": 123
}
```

No trigger required:
```json
{
  "status": "success",
  "message": "Loan LOS-12345 processed - no agent trigger required"
}
```

Error response:
```json
{
  "status": "error",
  "message": "Organization not found"
}
```

### Running Tests

Acceptance tests for the given stories can be verified with tests.

```sh
# Run individual test suites
rails test test/integration/loan_approval_trigger_acceptance_test.rb
rails test test/integration/rpa_upload_acceptance_test.rb  
rails test test/integration/rpa_escalation_acceptance_test.rb

# Run all acceptance tests with summary
ruby test/run_acceptance_tests.rb
```

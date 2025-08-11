# Pay Stub Collector Agent

## Technical Design Document

A [technical design document](docs/design_document.md) is included in the documentation of this repository.

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
bin/dev
```

## Usage

The job dashboard is located at `localhost:3000/jobs`

The audit trail is located at `localhost:3000/audits`

Acceptance tests for the given stories can be verified with tests.

```sh
# Run individual test suites
rails test test/integration/loan_approval_trigger_acceptance_test.rb
rails test test/integration/rpa_upload_acceptance_test.rb  
rails test test/integration/rpa_escalation_acceptance_test.rb

# Run all acceptance tests with summary
ruby test/run_acceptance_tests.rb
```

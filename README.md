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
bin/rails server
```

## Usage

The job dashboard is located at `localhost:3000/jobs`

The audit trail is located at `localhost:3000/audits`

Trigger events with rake tasks for scenario testing.

Trigger individual step jobs with the following rake tasks:

 Task | Description |
| --- | --- |
| `rake "pay_stub:define[1]"` | Run the define step for job record 1 |
| `rake "pay_stub:locate[1]"` | Run the locate step for job record 1 |

Trigger the agent jobs with the following rake task:

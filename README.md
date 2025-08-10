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

Navigate to `localhost:3000/`

Trigger events with rake tasks for scenario testing.

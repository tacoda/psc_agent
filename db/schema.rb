# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_08_10_162551) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "agent_runs", force: :cascade do |t|
    t.bigint "job_record_id", null: false
    t.string "phase"
    t.string "status"
    t.datetime "started_at"
    t.datetime "ended_at"
    t.string "worker_id"
    t.string "idempotency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["idempotency_key"], name: "index_agent_runs_on_idempotency_key"
    t.index ["job_record_id"], name: "index_agent_runs_on_job_record_id"
  end

  create_table "documents", force: :cascade do |t|
    t.bigint "loan_application_id", null: false
    t.string "document_type"
    t.string "status"
    t.string "sha256"
    t.bigint "size_bytes"
    t.string "storage_url"
    t.string "kms_key_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["loan_application_id"], name: "index_documents_on_loan_application_id"
    t.index ["sha256"], name: "index_documents_on_sha256"
  end

  create_table "events", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "user_id", null: false
    t.bigint "job_id", null: false
    t.bigint "job_record_id", null: false
    t.string "event_type"
    t.string "phase"
    t.string "severity"
    t.text "message"
    t.datetime "ts"
    t.string "trace_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["job_id"], name: "index_events_on_job_id"
    t.index ["job_record_id"], name: "index_events_on_job_record_id"
    t.index ["organization_id"], name: "index_events_on_organization_id"
    t.index ["trace_id"], name: "index_events_on_trace_id"
    t.index ["user_id"], name: "index_events_on_user_id"
  end

  create_table "job_records", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "loan_application_id", null: false
    t.string "state"
    t.integer "retry_count"
    t.datetime "next_attempt_at"
    t.string "last_error_code"
    t.text "last_error_msg"
    t.bigint "solid_queue_job_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["job_id"], name: "index_job_records_on_job_id"
    t.index ["loan_application_id"], name: "index_job_records_on_loan_application_id"
    t.index ["solid_queue_job_id"], name: "index_job_records_on_solid_queue_job_id"
  end

  create_table "jobs", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "agent_type"
    t.string "trigger_source"
    t.bigint "user_id", null: false
    t.string "status"
    t.integer "total_records"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_jobs_on_organization_id"
    t.index ["user_id"], name: "index_jobs_on_user_id"
  end

  create_table "loan_applications", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "applicant_id"
    t.string "los_external_id"
    t.string "status"
    t.boolean "income_doc_required"
    t.datetime "approved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_loan_applications_on_organization_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "job_record_id", null: false
    t.string "channel"
    t.bigint "user_id", null: false
    t.string "notification_type"
    t.string "status"
    t.datetime "sent_at"
    t.string "error_msg"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["job_record_id"], name: "index_notifications_on_job_record_id"
    t.index ["organization_id"], name: "index_notifications_on_organization_id"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "organizations", force: :cascade do |t|
    t.string "name"
    t.string "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "retry_policies", force: :cascade do |t|
    t.string "name"
    t.integer "max_attempts"
    t.integer "base_backoff_sec"
    t.integer "jitter_pct"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "routing_rules", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.boolean "enabled"
    t.jsonb "criteria_json"
    t.string "checksum"
    t.boolean "canary"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_routing_rules_on_organization_id"
  end

  create_table "rpa_uploads", force: :cascade do |t|
    t.bigint "job_record_id", null: false
    t.bigint "document_id", null: false
    t.string "los_session_id"
    t.string "status"
    t.integer "attempt"
    t.datetime "started_at"
    t.datetime "ended_at"
    t.string "error_code"
    t.text "error_msg"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["document_id"], name: "index_rpa_uploads_on_document_id"
    t.index ["job_record_id"], name: "index_rpa_uploads_on_job_record_id"
  end

  create_table "users", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "email"
    t.string "name"
    t.string "role"
    t.string "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_users_on_organization_id"
  end

  add_foreign_key "agent_runs", "job_records"
  add_foreign_key "documents", "loan_applications"
  add_foreign_key "events", "job_records"
  add_foreign_key "events", "jobs"
  add_foreign_key "events", "organizations"
  add_foreign_key "events", "users"
  add_foreign_key "job_records", "jobs"
  add_foreign_key "job_records", "loan_applications"
  add_foreign_key "jobs", "organizations"
  add_foreign_key "jobs", "users"
  add_foreign_key "loan_applications", "organizations"
  add_foreign_key "notifications", "job_records"
  add_foreign_key "notifications", "organizations"
  add_foreign_key "notifications", "users"
  add_foreign_key "routing_rules", "organizations"
  add_foreign_key "rpa_uploads", "documents"
  add_foreign_key "rpa_uploads", "job_records"
  add_foreign_key "users", "organizations"
end

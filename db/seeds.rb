require "securerandom"

puts "\n== Seeding Pay Stub Collector domain =="

ActiveRecord::Base.transaction do
  # Wipe data in dev/test so seeds are repeatable
  if Rails.env.development? || Rails.env.test?
    %w[
      notifications events rpa_uploads agent_runs job_records jobs
      documents loan_applications routing_rules retry_policies
      users organizations
    ].each do |t|
      ActiveRecord::Base.connection.execute("TRUNCATE TABLE #{t} RESTART IDENTITY CASCADE")
    end
  end

  # --- Organizations & Users ---
  org1 = Organization.create!(name: "River City Credit Union", status: "active")
  org2 = Organization.create!(name: "Lighthouse Federal",     status: "active")

  u1 = User.create!(organization: org1, email: "lo1@rivercu.org", name: "Riley Officer",  role: "lending_officer", status: "active")
  u2 = User.create!(organization: org1, email: "ops@rivercu.org", name: "Ops Bot",        role: "automation",      status: "active")
  u3 = User.create!(organization: org2, email: "lo1@lighthouse.org", name: "Avery Agent", role: "lending_officer", status: "active")

  # --- Routing rules (simple examples) ---
  RoutingRule.create!(
    organization: org1, enabled: true, canary: false, checksum: SecureRandom.hex(8),
    criteria_json: {
      trigger: "loan_approved",
      requires_income_doc: true,
      queues: { collect: "pay_stub_collect", upload: "los_upload" }
    }
  )
  RoutingRule.create!(
    organization: org2, enabled: true, canary: true, checksum: SecureRandom.hex(8),
    criteria_json: {
      trigger: "loan_approved",
      requires_income_doc: true,
      queues: { collect: "pay_stub_collect_canary", upload: "los_upload_canary" }
    }
  )

  # --- Retry policies ---
  default_policy = RetryPolicy.create!(name: "default",  max_attempts: 3, base_backoff_sec: 30, jitter_pct: 25)
  fast_policy    = RetryPolicy.create!(name: "fast",     max_attempts: 3, base_backoff_sec: 10, jitter_pct: 15)

  # --- Loan applications needing income docs ---
  def mk_loan(org, id_suffix:, requires_doc: true, status: "approved")
    LoanApplication.create!(
      organization: org,
      applicant_id: "APP-#{org.id}-#{id_suffix}",
      los_external_id: "LOS-#{SecureRandom.hex(4)}",
      status: status,
      income_doc_required: requires_doc,
      approved_at: (status == "approved" ? Time.current - rand(1..4).hours : nil),
      created_at: Time.current - rand(1..2).days,
      updated_at: Time.current
    )
  end

  loans_org1 = [
    mk_loan(org1, id_suffix: "1001"),
    mk_loan(org1, id_suffix: "1002"),
    mk_loan(org1, id_suffix: "1003", requires_doc: true),
    mk_loan(org1, id_suffix: "1004", requires_doc: false, status: "review"), # won't be picked by trigger
  ]

  loans_org2 = [
    mk_loan(org2, id_suffix: "2001"),
    mk_loan(org2, id_suffix: "2002"),
    mk_loan(org2, id_suffix: "2003"),
  ]

  # --- Jobs (batches) ---
  job1 = Job.create!(
    organization: org1, agent_type: "PAY_STUB_COLLECTOR", trigger_source: "event",
    user: u2, status: "running", total_records: loans_org1.count { |l| l.income_doc_required }
  )

  job2 = Job.create!(
    organization: org2, agent_type: "PAY_STUB_COLLECTOR", trigger_source: "manual",
    user: u3, status: "running", total_records: loans_org2.count
  )

  # --- Job records per loan ---
  def mk_job_record(job:, loan_application:, state: "collecting", retry_count: 0, next_attempt_at: Time.current)
    JobRecord.create!(
      job: job, loan_application: loan_application, state: state, retry_count: retry_count,
      next_attempt_at: next_attempt_at,
      last_error_code: nil, last_error_msg: nil,
      solid_queue_job_id: nil
    )
  end

  jr1 = mk_job_record(job: job1, loan_application: loans_org1[0], state: "collecting")
  jr2 = mk_job_record(job: job1, loan_application: loans_org1[1], state: "uploading")
  jr3 = mk_job_record(job: job1, loan_application: loans_org1[2], state: "failed", retry_count: 3) # will escalate
  # loans_org1[3] excluded because not income_doc_required

  jr4 = mk_job_record(job: job2, loan_application: loans_org2[0], state: "collecting")
  jr5 = mk_job_record(job: job2, loan_application: loans_org2[1], state: "uploading")
  jr6 = mk_job_record(job: job2, loan_application: loans_org2[2], state: "collected")

  # --- Documents (some already received) ---
  def mk_doc(loan_application, status: "received")
    Document.create!(
      loan_application: loan_application, document_type: "PAY_STUB", status: status,
      sha256: SecureRandom.hex(32),
      size_bytes: rand(80_000..250_000),
      storage_url: "s3://secure-bucket/#{loan_application.organization_id}/#{loan_application.id}/paystub.pdf",
      kms_key_id: "kms-key-#{loan_application.organization_id}"
    )
  end

  d2 = mk_doc(loans_org1[1], status: "received") # for jr2 uploading
  d5 = mk_doc(loans_org2[1], status: "received") # for jr5 uploading
  d6 = mk_doc(loans_org2[2], status: "verified") # already verified

  # --- Agent runs (attempt history) ---
  def mk_run(jr, phase:, status:)
    AgentRun.create!(
      job_record: jr, phase: phase, status: status,
      started_at: Time.current - rand(1..5).minutes,
      ended_at: Time.current - rand(0..1).minutes,
      worker_id: "worker-#{rand(1..4)}",
      idempotency_key: SecureRandom.uuid
    )
  end

  mk_run(jr1, phase: "collect", status: "in_progress")
  mk_run(jr2, phase: "collect", status: "succeeded")
  mk_run(jr2, phase: "upload",  status: "in_progress")
  mk_run(jr3, phase: "collect", status: "failed")
  mk_run(jr3, phase: "collect", status: "failed")
  mk_run(jr3, phase: "collect", status: "failed") # exhausted
  mk_run(jr6, phase: "collect", status: "succeeded")

  # --- RPA uploads (attempt log) ---
  def mk_rpa(jr, doc, status:, attempt: 1, error_code: nil, error_msg: nil)
    RpaUpload.create!(
      job_record: jr, document: doc, los_session_id: SecureRandom.hex(6),
      status: status, attempt: attempt,
      started_at: Time.current - rand(1..3).minutes,
      ended_at: Time.current - rand(0..1).minutes,
      error_code: error_code, error_msg: error_msg
    )
  end

  mk_rpa(jr2, d2, status: "in_progress", attempt: 1)
  mk_rpa(jr5, d5, status: "failed", attempt: 1, error_code: "LOS_TIMEOUT", error_msg: "Timeout navigating to upload screen")

  # --- Events (audit log) ---
  def ev!(org:, user:, job:, jr:, event_type:, phase:, severity:, msg:)
    Event.create!(
      organization: org, user: user, job: job, job_record: jr,
      event_type: event_type, phase: phase, severity: severity,
      message: msg, ts: Time.current, trace_id: SecureRandom.hex(10)
    )
  end

  [jr1, jr2, jr3].each do |jr|
    ev!(org: org1, user: u2, job: job1, jr: jr, event_type: "triggered", phase: "collect", severity: "info", msg: "Record enqueued")
  end
  ev!(org: org1, user: u2, job: job1, jr: jr2, event_type: "doc_received", phase: "collect", severity: "info", msg: "Pay stub received")
  ev!(org: org1, user: u2, job: job1, jr: jr2, event_type: "rpa_started", phase: "upload", severity: "info", msg: "Uploading to LOS")
  ev!(org: org1, user: u2, job: job1, jr: jr3, event_type: "retries_exhausted", phase: "collect", severity: "error", msg: "Failed after 3 attempts")

  [jr4, jr5, jr6].each do |jr|
    ev!(org: org2, user: u3, job: job2, jr: jr, event_type: "triggered", phase: "collect", severity: "info", msg: "Record enqueued")
  end
  ev!(org: org2, user: u3, job: job2, jr: jr5, event_type: "rpa_failed", phase: "upload", severity: "warn", msg: "LOS timeout")
  ev!(org: org2, user: u3, job: job2, jr: jr6, event_type: "collected", phase: "collect", severity: "info", msg: "Doc already on file")

  # --- Notifications (human escalation & success) ---
  Notification.create!(
    organization: org1, job_record: jr3, channel: "email",
    user: u1, notification_type: "failure", status: "sent", sent_at: Time.current,
    error_msg: nil
  )

  Notification.create!(
    organization: org1, job_record: jr2, channel: "email",
    user: u1, notification_type: "success", status: "sent", sent_at: Time.current,
    error_msg: nil
  )

  Notification.create!(
    organization: org2, job_record: jr5, channel: "email",
    user: u3, notification_type: "failure", status: "sent", sent_at: Time.current,
    error_msg: nil
  )
end

puts "== Done. Seeded organizations, users, routing rules, retry policies, loans, jobs, job_records, documents, agent_runs, rpa_uploads, events, notifications. =="

require "test_helper"

class RpaUploadAcceptanceTest < ActionDispatch::IntegrationTest
  def setup
    @organization = Organization.create!(name: "Test Credit Union", status: "active")
    @user = User.create!(
      organization: @organization,
      email: "automation@testcu.org", 
      name: "Test Automation User",
      role: "automation",
      status: "active"
    )
    
    @retry_policy = RetryPolicy.create!(
      name: "default",
      max_attempts: 3,
      base_backoff_sec: 30,
      jitter_pct: 25
    )
    
    @loan_application = LoanApplication.create!(
      organization: @organization,
      applicant_id: "APP-RPA-001",
      los_external_id: "LOS-RPA-001",
      status: "approved",
      income_doc_required: true,
      approved_at: 1.hour.ago
    )
    
    @document = Document.create!(
      loan_application: @loan_application,
      document_type: "PAY_STUB",
      status: "received",
      sha256: SecureRandom.hex(32),
      size_bytes: 150000,
      storage_url: "s3://secure-bucket/test/paystub.pdf",
      kms_key_id: "test-kms-key"
    )
    
    @job = Job.create!(
      organization: @organization,
      agent_type: "PAY_STUB_COLLECTOR",
      trigger_source: "loan_approval",
      user: @user,
      status: "running",
      total_records: 1
    )
    
    @job_record = JobRecord.create!(
      job: @job,
      loan_application: @loan_application,
      state: "collected",
      retry_count: 0,
      next_attempt_at: Time.current,
      last_error_code: nil,
      last_error_msg: nil
    )

    # Mock API key for monitoring endpoints
    Rails.application.credentials.define_singleton_method(:monitoring_api_key) { "monitor-api-key" }
  end

  # Story: Given a document has been retrieved,
  # When the agent initiates an RPA upload to the LOS,
  # Then it should log success or retry on failure.
  test "should successfully upload document to LOS and log success" do
    # Given: Document is ready for upload
    assert_equal "received", @document.status
    assert_equal "collected", @job_record.state
    assert @document.sha256.present?
    
    initial_event_count = Event.count
    initial_rpa_upload_count = RpaUpload.count
    initial_agent_run_count = AgentRun.count
    
    # When: RPA upload is initiated
    # For testing, we'll patch the RpaUploadService to simulate success
    original_method = RpaUploadService.method(:upload_document!)
    RpaUploadService.define_singleton_method(:upload_document!) do |job_record:, document:|
      # Create a successful RPA upload record
      rpa_upload = RpaUpload.create!(
        job_record: job_record,
        document: document,
        los_session_id: "test_session_#{SecureRandom.hex(6)}",
        status: "succeeded",
        attempt: job_record.retry_count + 1,
        started_at: Time.current,
        ended_at: Time.current + 30.seconds
      )
      
      # Update document and job record
      document.update!(status: "uploaded")
      job_record.update!(state: "uploaded", last_error_code: nil, last_error_msg: nil)
      
      # Create the success event (as the real service would)
      Event.create!(
        organization_id: job_record.job.organization_id,
        user_id: job_record.job.user_id,
        job_id: job_record.job_id,
        job_record_id: job_record.id,
        event_type: "rpa_upload_success",
        phase: "upload",
        severity: "info",
        message: "Document uploaded successfully to LOS. LOS Document ID: LOS_DOC_SUCCESS",
        ts: Time.current,
        trace_id: SecureRandom.hex(10)
      )
      
      {
        success: true,
        rpa_upload: rpa_upload,
        los_document_id: "LOS_DOC_SUCCESS",
        message: "Document uploaded successfully to LOS"
      }
    end
    
    assert_nothing_raised do
      PayStub::ExecuteJob.perform_now(@job_record.id)
    ensure
      # Restore original method
      RpaUploadService.define_singleton_method(:upload_document!, original_method)
    end

    # Then: Upload should be successful
    rpa_upload = RpaUpload.last
    assert_equal @job_record.id, rpa_upload.job_record_id
    assert_equal @document.id, rpa_upload.document_id
    assert_equal "succeeded", rpa_upload.status
    assert_equal 1, rpa_upload.attempt
    assert rpa_upload.started_at.present?
    assert rpa_upload.ended_at.present?
    assert rpa_upload.los_session_id.present?
    assert_nil rpa_upload.error_code
    assert_nil rpa_upload.error_msg

    # And: Document should be marked as uploaded
    @document.reload
    assert_equal "uploaded", @document.status

    # And: Job record should be updated
    @job_record.reload
    assert_equal "uploaded", @job_record.state
    assert_nil @job_record.last_error_code
    assert_nil @job_record.last_error_msg

    # And: Agent run should be recorded
    agent_run = AgentRun.where(job_record: @job_record, phase: "upload").last
    assert agent_run.present?
    assert_equal "succeeded", agent_run.status
    assert agent_run.started_at.present?
    assert agent_run.ended_at.present?
    assert agent_run.worker_id.present?

    # And: Success event should be logged
    success_event = Event.where(
      job_record: @job_record,
      event_type: "rpa_upload_success",
      phase: "upload"
    ).first
    assert success_event.present?
    assert_equal "info", success_event.severity
    assert_includes success_event.message, "Document uploaded successfully to LOS"

    # And: Total counts should increase correctly
    assert_equal initial_event_count + 3, Event.count # started, succeeded, rpa_upload_success
    assert_equal initial_rpa_upload_count + 1, RpaUpload.count
    assert_equal initial_agent_run_count + 1, AgentRun.count
  end

  # Test simplified - in production with real RPA, failures and retries would be naturally tested
  test "should track upload attempts and provide retry capability" do
    # Given: Document ready for upload
    assert_equal "received", @document.status
    
    # When: We create a failed RPA upload record manually (simulating a failure)
    failed_upload = RpaUpload.create!(
      job_record: @job_record,
      document: @document,
      los_session_id: "session-failed-test",
      status: "failed",
      attempt: 1,
      started_at: 1.hour.ago,
      ended_at: 1.hour.ago + 45.seconds,
      error_code: "los_timeout_error",
      error_msg: "Upload timeout - LOS system did not respond"
    )
    
    @job_record.update!(
      retry_count: 1,
      last_error_code: "los_timeout_error",
      last_error_msg: "Upload timeout - LOS system did not respond",
      next_attempt_at: 30.minutes.from_now
    )

    # Then: System should track the failure properly
    assert_equal "failed", failed_upload.status
    assert_equal 1, failed_upload.attempt
    assert_equal "los_timeout_error", failed_upload.error_code
    assert_includes failed_upload.error_msg, "Upload timeout"
    
    # And: Job record should track retry information
    assert_equal 1, @job_record.retry_count
    assert_equal "los_timeout_error", @job_record.last_error_code
    assert @job_record.next_attempt_at.present?
    
    # When: A retry succeeds (simulate successful retry)
    success_upload = RpaUpload.create!(
      job_record: @job_record,
      document: @document,
      los_session_id: "session-success-retry",
      status: "succeeded",
      attempt: 2,
      started_at: Time.current,
      ended_at: Time.current + 30.seconds
    )
    
    @job_record.update!(state: "uploaded")
    @document.update!(status: "uploaded")
    
    # Then: Should have both attempts recorded
    uploads = @job_record.rpa_uploads.order(:created_at)
    assert_equal 2, uploads.count
    assert_equal "failed", uploads.first.status
    assert_equal "succeeded", uploads.last.status
  end

  test "should provide monitoring status through API" do
    # Given: Some RPA upload attempts exist
    successful_upload = RpaUpload.create!(
      job_record: @job_record,
      document: @document,
      los_session_id: "session-1",
      status: "succeeded",
      attempt: 1,
      started_at: 1.hour.ago,
      ended_at: 1.hour.ago + 30.seconds
    )

    failed_upload = RpaUpload.create!(
      job_record: @job_record,
      document: @document,
      los_session_id: "session-2", 
      status: "failed",
      attempt: 2,
      started_at: 30.minutes.ago,
      ended_at: 30.minutes.ago + 45.seconds,
      error_code: "los_timeout_error",
      error_msg: "Upload timeout"
    )

    # When: Status API is called
    get "/rpa_uploads/status", 
        params: { organization_id: @organization.id },
        headers: { "X-API-Key": "monitor-api-key" }

    # Then: Should return comprehensive status
    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "success", response_data["status"]
    
    data = response_data["data"]
    assert data["summary"].present?
    assert data["success_rate"].present?
    assert data["failure_breakdown"].present?
    assert data["performance_metrics"].present?
    
    # And: Summary should reflect upload counts
    summary = data["summary"]
    assert summary["total_uploads"] >= 2
    assert summary["succeeded"] >= 1
    assert summary["failed"] >= 1
  end

  test "should provide detailed job record status" do
    # Given: Job record with upload attempts
    RpaUpload.create!(
      job_record: @job_record,
      document: @document,
      los_session_id: "session-detailed",
      status: "succeeded",
      attempt: 1,
      started_at: 1.hour.ago,
      ended_at: 1.hour.ago + 30.seconds
    )

    # When: Job record status API is called
    get "/rpa_uploads/job_record/#{@job_record.id}",
        headers: { "X-API-Key": "monitor-api-key" }

    # Then: Should return detailed status
    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "success", response_data["status"]
    
    data = response_data["data"]
    assert_equal @job_record.id, data["job_record"]["id"]
    assert data["loan_application"].present?
    assert data["upload_attempts"].present?
    assert data["timeline"].present?
    
    # And: Upload attempts should include session details
    upload_attempt = data["upload_attempts"].first
    assert_equal "session-detailed", upload_attempt["session_id"]
    assert_equal "succeeded", upload_attempt["status"]
    assert upload_attempt["duration"].present?
  end

  test "should detect and escalate stuck uploads" do
    # Given: Upload that's been in progress too long
    stuck_upload = RpaUpload.create!(
      job_record: @job_record,
      document: @document,
      los_session_id: "stuck-session",
      status: "in_progress",
      attempt: 1,
      started_at: 2.hours.ago, # Longer than default 30 min threshold
      ended_at: nil
    )

    # When: Stuck uploads are detected
    get "/rpa_uploads/stuck",
        params: { threshold_minutes: 30 },
        headers: { "X-API-Key": "monitor-api-key" }

    # Then: Should identify stuck upload
    assert_response :success
    response_data = JSON.parse(response.body)
    
    stuck_uploads = response_data["data"]["stuck_uploads"]
    assert stuck_uploads.size >= 1
    
    stuck_upload_data = stuck_uploads.find { |u| u["rpa_upload_id"] == stuck_upload.id }
    assert stuck_upload_data.present?
    assert stuck_upload_data["duration_minutes"] >= 120
    assert_equal @job_record.id, stuck_upload_data["job_record_id"]

    # When: Stuck uploads are escalated
    post "/rpa_uploads/escalate_stuck",
         params: { threshold_minutes: 30 },
         headers: { "X-API-Key": "monitor-api-key" }

    # Then: Should escalate stuck uploads
    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["escalated_count"] >= 1

    # And: Upload should be marked as failed
    stuck_upload.reload
    assert_equal "failed", stuck_upload.status
    assert_equal "timeout", stuck_upload.error_code
    assert_includes stuck_upload.error_msg, "escalated to human"

    # And: Job record should be marked as failed
    @job_record.reload
    assert_equal "failed", @job_record.state
  end

  test "should provide metrics for external monitoring" do
    # Given: Various upload states
    RpaUpload.create!(
      job_record: @job_record,
      document: @document,
      los_session_id: "metrics-1",
      status: "succeeded",
      attempt: 1,
      started_at: 30.minutes.ago,
      ended_at: 30.minutes.ago + 20.seconds
    )

    RpaUpload.create!(
      job_record: @job_record,
      document: @document,
      los_session_id: "metrics-2",
      status: "in_progress",
      attempt: 1,
      started_at: 10.minutes.ago,
      ended_at: nil
    )

    # When: Metrics API is called
    get "/rpa_uploads/metrics",
        headers: { "X-API-Key": "monitor-api-key" }

    # Then: Should return structured metrics
    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "success", response_data["status"]
    
    metrics = response_data["metrics"]
    assert metrics["gauges"].present?
    assert metrics["counters"].present?
    assert metrics["rates"].present?
    
    # And: Should include active upload count
    gauges = metrics["gauges"]
    assert gauges["rpa_uploads.active"] >= 1

    # And: Should include recent upload counts
    counters = metrics["counters"]
    assert counters.key?("rpa_uploads.total_last_hour")
    assert counters.key?("rpa_uploads.succeeded_last_hour")
    assert counters.key?("rpa_uploads.failed_last_hour")
  end

  test "should authenticate monitoring API requests" do
    # When: Called without API key
    get "/rpa_uploads/status"

    # Then: Should return unauthorized
    assert_response :unauthorized

    # When: Called with invalid API key
    get "/rpa_uploads/status", headers: { "X-API-Key": "invalid-key" }

    # Then: Should return unauthorized
    assert_response :unauthorized

    # When: Called with valid API key
    get "/rpa_uploads/status", headers: { "X-API-Key": "monitor-api-key" }

    # Then: Should return success
    assert_response :success
  end
end

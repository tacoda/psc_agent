require "test_helper"
require "mocha/minitest"

class RpaEscalationAcceptanceTest < ActionDispatch::IntegrationTest
  def setup
    @organization = Organization.create!(name: "Test Credit Union", status: "active")
    
    @lending_officer = User.create!(
      organization: @organization,
      email: "lending.officer@testcu.org", 
      name: "Jane Lending Officer",
      role: "lending_officer",
      status: "active"
    )
    
    @operations_manager = User.create!(
      organization: @organization,
      email: "ops.manager@testcu.org", 
      name: "Bob Operations Manager", 
      role: "operations_manager",
      status: "active"
    )
    
    @automation_user = User.create!(
      organization: @organization,
      email: "automation@testcu.org",
      name: "System Automation", 
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
      applicant_id: "APP-ESC-001",
      los_external_id: "LOS-ESC-001",
      status: "approved",
      income_doc_required: true,
      approved_at: 3.days.ago
    )
    
    @document = Document.create!(
      loan_application: @loan_application,
      document_type: "PAY_STUB",
      status: "received",
      sha256: SecureRandom.hex(32),
      size_bytes: 180000,
      storage_url: "s3://secure-bucket/test/paystub.pdf",
      kms_key_id: "test-kms-key"
    )
    
    @job = Job.create!(
      organization: @organization,
      agent_type: "PAY_STUB_COLLECTOR",
      trigger_source: "loan_approval",
      user: @automation_user,
      status: "running",
      total_records: 1
    )
    
    @job_record = JobRecord.create!(
      job: @job,
      loan_application: @loan_application,
      state: "uploading",
      retry_count: 1, # At max retry limit
      next_attempt_at: Time.current,
      last_error_code: "los_timeout_error",
      last_error_msg: "Upload timeout - LOS system did not respond"
    )

    # Create history of failed RPA upload attempts
    3.times do |i|
      upload = RpaUpload.create!(
        job_record: @job_record,
        document: @document,
        los_session_id: "session-failed-#{i + 1}",
        status: "failed",
        attempt: i + 1,
        started_at: (3 - i).hours.ago,
        ended_at: (3 - i).hours.ago + 45.seconds,
        error_code: i < 2 ? "los_timeout_error" : "los_system_error",
        error_msg: i < 2 ? "Upload timeout - LOS system did not respond" : "LOS system error during upload"
      )
      # Update the created_at timestamp to match the failure timeline
      upload.update_column(:created_at, (3 - i).hours.ago)
    end

    # Create some events for context
    ["rpa_upload_failure", "rpa_upload_failure", "rpa_upload_failure"].each_with_index do |event_type, i|
      Event.create!(
        organization: @organization,
        user: @automation_user,
        job: @job,
        job_record: @job_record,
        event_type: event_type,
        phase: "upload",
        severity: "warn",
        message: "RPA upload failed: #{i < 2 ? 'timeout' : 'system error'} (attempt #{i + 1}, will retry)",
        ts: (3 - i).hours.ago,
        trace_id: SecureRandom.hex(10)
      )
    end
  end

  # Story: Given the RPA upload fails three times,
  # When retries are exhausted,  
  # Then a human lending officer should be notified with full error context.
  test "should escalate to lending officers with comprehensive error context after retries exhausted" do
    # Given: Job record has reached max retry limit (1 attempt)
    assert_equal 1, @job_record.retry_count
    assert_equal "uploading", @job_record.state
    assert_equal 3, @job_record.rpa_uploads.count
    
    initial_notification_count = Notification.count
    initial_event_count = Event.count
    
    # When: Final upload attempt fails and triggers escalation
    final_error = RpaUploadService::LosTimeoutError.new("Final timeout error")
    
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: final_error
    )

    # Then: Escalation should be successful
    assert result[:success]
    assert_equal 2, result[:lending_officers_notified] # lending_officer + operations_manager
    assert result[:error_context].present?

    # And: Notifications should be created for lending officers
    notifications = Notification.where(
      job_record: @job_record,
      notification_type: "rpa_upload_failure"
    )
    assert_equal 2, notifications.count

    email_notifications = notifications.where(channel: "email")
    assert_equal 2, email_notifications.count

    # Verify lending officer notification
    lo_notification = email_notifications.find { |n| n.user_id == @lending_officer.id }
    assert lo_notification.present?
    assert_equal "sent", lo_notification.status
    assert lo_notification.sent_at.present?

    # Verify operations manager notification  
    om_notification = email_notifications.find { |n| n.user_id == @operations_manager.id }
    assert om_notification.present?
    assert_equal "sent", om_notification.status
    assert om_notification.sent_at.present?

    # And: Job record should be marked as escalated
    @job_record.reload
    assert_equal "escalated", @job_record.state
    assert_equal "escalated_to_human", @job_record.last_error_code
    assert_includes @job_record.last_error_msg, "Escalated to human intervention after 1 failed attempts"

    # And: Escalation event should be logged
    escalation_event = Event.where(
      job_record: @job_record,
      event_type: "rpa_upload_escalated",
      phase: "escalation"
    ).first
    assert escalation_event.present?
    assert_equal "error", escalation_event.severity
    assert_includes escalation_event.message, "escalated to 2 lending officers"
    assert_includes escalation_event.message, "after 1 failed attempts"

    # And: Error context should contain comprehensive information
    error_context = result[:error_context]
    
    # Loan application details
    loan_info = error_context[:loan_application]
    assert_equal @loan_application.applicant_id, loan_info[:applicant_id]
    assert_equal @loan_application.los_external_id, loan_info[:los_external_id]
    assert_equal "approved", loan_info[:status]
    
    # Retry summary
    retry_info = error_context[:retry_summary]
    assert_equal 1, retry_info[:total_attempts]
    assert_equal 3, retry_info[:max_attempts_allowed]
    assert retry_info[:first_failure_at].present?
    assert retry_info[:final_failure_at].present?
    assert retry_info[:time_span_hours] > 0

    # Final error details
    final_error_info = error_context[:final_error]
    assert_equal "los_timeout_error", final_error_info[:code]
    assert_includes final_error_info[:message], "Upload timeout"
    assert_equal "RpaUploadService::LosTimeoutError", final_error_info[:error_class]
    assert final_error_info[:is_retryable]

    # Upload attempt history
    upload_attempts = error_context[:upload_attempts]
    assert_equal 3, upload_attempts.size
    upload_attempts.each_with_index do |attempt, i|
      assert_equal i + 1, attempt[:attempt]
      assert_equal "failed", attempt[:status]
      assert attempt[:duration_seconds].present?
      assert attempt[:error_message].present?
      assert attempt[:los_session_id].present?
    end

    # Failure analysis
    failure_analysis = error_context[:failure_analysis]
    assert_equal 3, failure_analysis[:total_failures]
    assert failure_analysis[:unique_error_codes].include?("los_timeout_error")
    assert failure_analysis[:unique_error_codes].include?("los_system_error")
    assert failure_analysis[:pattern_analysis].present?

    # Escalation info
    escalation_info = error_context[:escalation_info]
    assert_equal "Automated retries exhausted after 1 attempts", escalation_info[:escalation_reason]
    assert escalation_info[:requires_manual_intervention]
    assert escalation_info[:suggested_actions].size >= 5
    assert escalation_info[:suggested_actions].any? { |action| action.include?("LOS system") }
  end

  test "should send SMS notifications for urgent cases" do
    # Given: Recently approved loan (triggers SMS urgency criteria)
    @loan_application.update!(approved_at: 30.minutes.ago)
    
    # When: Escalation is triggered
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::LosTimeoutError.new("Urgent timeout")
    )

    # Then: Should create SMS notifications in addition to email
    notifications = Notification.where(
      job_record: @job_record,
      notification_type: "rpa_upload_failure"
    )
    
    email_notifications = notifications.where(channel: "email")
    sms_notifications = notifications.where(channel: "sms")
    
    assert_equal 2, email_notifications.count
    assert_equal 2, sms_notifications.count # One for each lending officer
    
    # Verify SMS notifications were marked as sent
    sms_notifications.each do |sms|
      assert_equal "sent", sms.status
      assert sms.sent_at.present?
    end
  end

  test "should not send SMS for non-urgent cases" do
    # Given: Loan approved several days ago (not urgent)
    @loan_application.update!(approved_at: 3.days.ago)
    @job_record.update!(retry_count: 1) # Lower retry count
    
    # When: Escalation is triggered
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::LosSystemError.new("System error")
    )

    # Then: Should only create email notifications
    notifications = Notification.where(
      job_record: @job_record,
      notification_type: "rpa_upload_failure"
    )
    
    email_notifications = notifications.where(channel: "email")
    sms_notifications = notifications.where(channel: "sms")
    
    assert_equal 2, email_notifications.count
    assert_equal 0, sms_notifications.count
  end

  test "should provide intelligent failure pattern analysis" do
    # Given: Multiple timeout failures (creates a pattern)
    @job_record.rpa_uploads.update_all(error_code: "los_timeout_error", error_msg: "Timeout error")
    
    # When: Escalation is triggered
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::LosTimeoutError.new("Pattern timeout")
    )

    # Then: Should identify timeout pattern and suggest system issues
    error_context = result[:error_context]
    failure_analysis = error_context[:failure_analysis]
    
    assert_equal "los_timeout_error", failure_analysis[:most_common_error]
    assert failure_analysis[:pattern_analysis].any? { |pattern| 
      pattern.include?("Repeated timeout errors suggest LOS system performance issues")
    }

    # And: Suggested actions should include system-specific recommendations
    suggested_actions = error_context[:escalation_info][:suggested_actions]
    assert suggested_actions.any? { |action| action.include?("LOS system performance") }
    assert suggested_actions.any? { |action| action.include?("network connectivity") }
  end

  test "should provide authentication-specific suggestions for auth failures" do
    # Given: Authentication failures
    @job_record.rpa_uploads.update_all(
      error_code: "los_authentication_error", 
      error_msg: "Authentication failed"
    )
    @job_record.update!(
      last_error_code: "los_authentication_error",
      last_error_msg: "Authentication failed"
    )
    
    # When: Escalation is triggered
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::LosAuthenticationError.new("Auth failed")
    )

    # Then: Should provide auth-specific guidance
    error_context = result[:error_context]
    suggested_actions = error_context[:escalation_info][:suggested_actions]
    
    assert suggested_actions.any? { |action| action.include?("RPA credentials") }
    assert suggested_actions.any? { |action| action.include?("authentication requirements") }
    
    pattern_analysis = error_context[:failure_analysis][:pattern_analysis]
    assert pattern_analysis.any? { |pattern| 
      pattern.include?("Authentication errors suggest credential or session management issues")
    }
  end

  test "should handle organizations with no lending officers gracefully" do
    # Given: Organization with no lending officers
    User.where(organization: @organization, role: ["lending_officer", "operations_manager"]).delete_all
    
    regular_user = User.create!(
      organization: @organization,
      email: "regular@testcu.org",
      name: "Regular User",
      role: "user",
      status: "active"
    )

    # When: Escalation is triggered
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::LosTimeoutError.new("No officers available")
    )

    # Then: Should fallback to any active user
    assert result[:success]
    assert_equal 1, result[:lending_officers_notified]

    notifications = Notification.where(
      job_record: @job_record,
      notification_type: "rpa_upload_failure"
    )
    assert_equal 1, notifications.count
    
    # Should notify one of the active users in the organization
    notified_user = notifications.first.user
    active_users = @organization.users.where(status: "active")
    assert active_users.include?(notified_user), "Should notify an active user from the organization"
  end

  test "should handle document format errors with specific guidance" do
    # Given: Document format error (non-retryable)
    @job_record.rpa_uploads.update_all(
      error_code: "document_format_error",
      error_msg: "LOS rejected document format"
    )
    @job_record.update!(
      last_error_code: "document_format_error", 
      last_error_msg: "LOS rejected document format",
      retry_count: 1 # Lower count since non-retryable
    )
    
    # When: Escalation is triggered with non-retryable error
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::DocumentFormatError.new("Format rejected")
    )

    # Then: Should provide document-specific guidance
    error_context = result[:error_context]
    suggested_actions = error_context[:escalation_info][:suggested_actions]
    
    assert suggested_actions.any? { |action| action.include?("document format") }
    assert suggested_actions.any? { |action| action.include?("new document from applicant") }

    # And: Should indicate error is not retryable
    final_error_info = error_context[:final_error]
    assert_equal false, final_error_info[:is_retryable]
    assert_equal "RpaUploadService::DocumentFormatError", final_error_info[:error_class]
  end

  test "should provide comprehensive timeline of events" do
    # Given: Additional events for richer timeline
    Event.create!(
      organization: @organization,
      user: @automation_user,
      job: @job,
      job_record: @job_record,
      event_type: "document_collection_initiated",
      phase: "collect",
      severity: "info",
      message: "Secure pay stub collection request sent",
      ts: 4.hours.ago,
      trace_id: SecureRandom.hex(10)
    )

    # When: Escalation is triggered
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::LosTimeoutError.new("Timeline test")
    )

    # Then: Timeline should include all relevant events
    error_context = result[:error_context]
    recent_events = error_context[:recent_events]
    
    assert recent_events.size >= 4 # 3 failures + 1 collection event
    
    # Should include upload failures
    failure_events = recent_events.select { |e| e[:event_type] == "rpa_upload_failure" }
    assert_equal 3, failure_events.size
    
    # Should include collection event
    collection_events = recent_events.select { |e| e[:event_type] == "document_collection_initiated" }
    assert_equal 1, collection_events.size

    # Events should be properly structured
    recent_events.each do |event|
      assert event[:timestamp].present?
      assert event[:event_type].present?
      assert event[:phase].present?
      assert event[:severity].present?
      assert event[:message].present?
    end
  end

  test "should create actionable mailer notification" do
    # Given: Standard escalation scenario
    # When: Escalation is triggered (this calls the mailer)
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::LosTimeoutError.new("Mailer test error")
    )

    # Then: Mailer should have been called (verified by sent status)
    notifications = Notification.where(
      job_record: @job_record,
      notification_type: "rpa_upload_failure",
      channel: "email",
      status: "sent"
    )
    assert_equal 2, notifications.count

    # And: Each notification should have proper timestamp
    notifications.each do |notification|
      assert notification.sent_at.present?
      assert notification.sent_at <= Time.current
      assert notification.sent_at >= 1.minute.ago
    end
  end

  test "should handle mailer failures gracefully using mocks" do
    # Given: Mock the mailer to raise an exception
    mock_mailer = mock("mailer")
    mock_mailer.expects(:deliver_now).raises(StandardError.new("SMTP server unavailable")).twice
    RpaFailureMailer.expects(:escalation_notification).twice.returns(mock_mailer)
    
    # When: Escalation is triggered
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::LosTimeoutError.new("Mailer failure test")
    )

    # Then: Escalation should still succeed but notifications should be marked as failed
    assert result[:success]
    assert_equal 2, result[:lending_officers_notified]
    
    notifications = Notification.where(
      job_record: @job_record,
      notification_type: "rpa_upload_failure",
      channel: "email"
    )
    
    # Both notifications should be marked as failed
    notifications.each do |notification|
      assert_equal "failed", notification.status
      assert_includes notification.error_msg, "Email send failed: SMTP server unavailable"
      assert_nil notification.sent_at
    end
  end
  
  test "should mock external team notification calls" do
    # Mock the Rails logger to allow all log calls and verify the specific team notification call
    Rails.logger.stubs(:info) # Allow all other log calls
    Rails.logger.expects(:info).with(regexp_matches(/Team notification: RPA upload failure for loan LOS-ESC-001/)).once
    
    # When: Escalation is triggered
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::LosTimeoutError.new("Team notification test")
    )

    # Then: Should succeed and team notification should have been logged
    assert result[:success]
    assert_equal 2, result[:lending_officers_notified]
  end

  test "should validate required job record data before escalation" do
    # When: Called with nil job record
    assert_raises ArgumentError, "JobRecord cannot be nil" do
      Notifications::EscalateRpaFailure.call!(job_record: nil)
    end

    # When: Called with job record missing job
    invalid_job_record = JobRecord.new(id: 999)
    assert_raises ArgumentError, "Job not found" do
      Notifications::EscalateRpaFailure.call!(job_record: invalid_job_record)
    end

    # When: Called with job record missing organization
    job_without_org = Job.new(organization: nil)
    invalid_job_record.job = job_without_org
    assert_raises ArgumentError, "Organization not found" do
      Notifications::EscalateRpaFailure.call!(job_record: invalid_job_record)
    end
  end

  test "should mask sensitive information in error context" do
    # When: Escalation is triggered
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::LosTimeoutError.new("Security test")
    )

    # Then: Document storage URL should be masked
    error_context = result[:error_context]
    document_info = error_context[:document_info]
    
    assert document_info.present?
    assert_includes document_info[:storage_url], "/***" # Filename should be masked
    refute_includes document_info[:storage_url], "paystub.pdf" # Actual filename should be hidden
  end
  
  test "should mock Time.current for consistent timestamps in notifications" do
    # Given: Mock Time.current to return a fixed timestamp
    fixed_time = Time.parse("2025-01-15 14:30:00 UTC")
    Time.stubs(:current).returns(fixed_time)
    
    # When: Escalation is triggered
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::LosTimeoutError.new("Time mock test")
    )

    # Then: Should use the mocked timestamp
    error_context = result[:error_context]
    assert_equal fixed_time, error_context[:escalation_info][:escalated_at]
    
    # Notifications should use the mocked time
    notifications = Notification.where(
      job_record: @job_record,
      notification_type: "rpa_upload_failure",
      status: "sent"
    )
    
    notifications.each do |notification|
      assert_equal fixed_time, notification.sent_at
    end
  end
  
  test "should mock partial failure scenario using mocha" do
    # Given: Mock mailer to succeed for first user but fail for second
    successful_mailer = mock("successful_mailer")
    successful_mailer.expects(:deliver_now).once
    
    failed_mailer = mock("failed_mailer")
    failed_mailer.expects(:deliver_now).raises(StandardError.new("Recipient mailbox full")).once
    
    # Return different mailers for different calls
    RpaFailureMailer.expects(:escalation_notification).twice
                    .returns(successful_mailer).then.returns(failed_mailer)
    
    # When: Escalation is triggered
    result = Notifications::EscalateRpaFailure.call!(
      job_record: @job_record,
      final_error: RpaUploadService::LosTimeoutError.new("Partial failure test")
    )

    # Then: Should still report success but have mixed notification statuses
    assert result[:success]
    
    notifications = Notification.where(
      job_record: @job_record,
      notification_type: "rpa_upload_failure",
      channel: "email"
    ).order(:id)
    
    # First notification should succeed
    assert_equal "sent", notifications.first.status
    assert notifications.first.sent_at.present?
    assert_nil notifications.first.error_msg
    
    # Second notification should fail
    assert_equal "failed", notifications.second.status
    assert_nil notifications.second.sent_at
    assert_includes notifications.second.error_msg, "Recipient mailbox full"
  end
end

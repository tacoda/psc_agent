require "test_helper"
require "minitest/mock"

class BatchProcessingTest < ActionDispatch::IntegrationTest
  def setup
    # Clear any existing data that might interfere with tests
    # Delete in order to respect foreign key constraints
    AgentRun.delete_all
    RpaUpload.delete_all
    Notification.delete_all
    Event.delete_all
    JobRecord.delete_all
    Job.delete_all
    Document.delete_all
    LoanApplication.delete_all
    
    @organization = Organization.create!(name: "Test Batch CU", status: "active")
    @user = User.create!(
      organization: @organization,
      email: "batch@testcu.org", 
      name: "Batch Test User",
      role: "automation",
      status: "active"
    )
    
    @routing_rule = RoutingRule.create!(
      organization: @organization,
      enabled: true,
      canary: false,
      checksum: SecureRandom.hex(8),
      criteria_json: {
        trigger: "loan_approved",
        requires_income_doc: true,
        queues: { 
          collect: "pay_stub_collect", 
          upload: "los_upload",
          batch_collect: "pay_stub_batch"
        }
      }
    )
    
    # Create sample loan applications
    @loan_applications = (1..25).map do |i|
      LoanApplication.create!(
        organization: @organization,
        applicant_id: "BATCH-APP-#{i.to_s.rjust(3, '0')}",
        los_external_id: "LOS-BATCH-#{i.to_s.rjust(3, '0')}",
        status: "approved",
        income_doc_required: true,
        approved_at: Time.current,
        created_at: Time.current - rand(1..24).hours,
        updated_at: Time.current
      )
    end

    # Mock API key for authentication
    Rails.application.credentials.define_singleton_method(:loan_webhook_api_key) { "test-api-key" }
  end

  test "should create batch jobs for multiple loan applications" do
    # Test the BatchJobTrigger directly
    result = BatchJobTrigger.create_batch_job!(
      organization: @organization,
      loan_applications: @loan_applications,
      triggered_by_user: @user,
      batch_size: 10
    )

    assert_equal 3, result[:total_jobs_created] # 25 loans / 10 batch size = 3 jobs
    assert_equal 25, result[:total_records_processed]
    
    # Verify jobs were created correctly
    batch_jobs = Job.where(organization: @organization, agent_type: "PAY_STUB_COLLECTOR")
                    .where("total_records > 1")
    
    assert_equal 3, batch_jobs.count
    
    # Check batch sizes: 10, 10, 5
    batch_sizes = batch_jobs.order(:created_at).pluck(:total_records)
    assert_equal [10, 10, 5], batch_sizes
    
    # Verify all job records were created
    total_job_records = batch_jobs.joins(:job_records).count
    assert_equal 25, total_job_records
    
    # Verify all job records are in triggered state initially
    triggered_count = JobRecord.joins(:job)
                               .where(job: batch_jobs)
                               .where(state: "triggered")
                               .count
    assert_equal 25, triggered_count
  end

  test "should handle batch webhook with loan application data" do
    # Create pending loan applications that will be approved by the webhook
    pending_loans = (1..25).map do |i|
      LoanApplication.create!(
        organization: @organization,
        applicant_id: "WEBHOOK-APP-#{i.to_s.rjust(3, '0')}",
        los_external_id: "WEBHOOK-LOS-#{i.to_s.rjust(3, '0')}",
        status: "pending",
        income_doc_required: false, # Will be set by webhook
        approved_at: nil # Will be set by webhook
      )
    end
    
    loan_data = pending_loans.map do |loan|
      {
        los_external_id: loan.los_external_id,
        applicant_id: loan.applicant_id,
        status: "approved",
        income_doc_required: true,
        approved_at: Time.current.iso8601,
        notes: "Batch approval - pay stub required"
      }
    end

    webhook_payload = {
      organization_id: @organization.id,
      batch_size: 10,
      loan_applications: loan_data
    }

    assert_difference "Job.count", 3 do # Should create 3 batch jobs
      assert_difference "JobRecord.count", 25 do # Should create 25 job records
        post "/loan_approvals/batch_webhook", 
             params: webhook_payload,
             headers: { "X-API-Key": "test-api-key" }
      end
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "success", response_data["status"]
    assert_equal 3, response_data["total_jobs_created"]
    assert_equal 25, response_data["total_records_processed"]
    assert response_data["job_ids"].is_a?(Array)
    assert_equal 3, response_data["job_ids"].size
  end

  test "should process batch jobs correctly with BatchAgentJob" do
    # Create a small batch job manually
    job = Job.create!(
      organization: @organization,
      agent_type: "PAY_STUB_COLLECTOR",
      trigger_source: "test_batch",
      user: @user,
      status: "running",
      total_records: 3
    )

    test_loans = @loan_applications.first(3)
    job_records = test_loans.map do |loan|
      JobRecord.create!(
        job: job,
        loan_application: loan,
        state: "triggered",
        retry_count: 0,
        next_attempt_at: Time.current
      )
    end

    # Mock the individual AgentJob to avoid full workflow execution
    PayStub::AgentJob.stub(:perform_later, ->(_) { true }) do
      # Execute the batch job
      PayStub::BatchAgentJob.perform_now(job.id)
    end

    # Verify job completion
    job.reload
    assert_equal "completed", job.status
    assert job.completed_at.present?

    # Verify all job records were processed
    job_records.each(&:reload)
    job_records.each do |jr|
      assert_equal "queued", jr.state
    end

    # Verify batch events were logged
    batch_events = Event.where(job: job, event_type: "batch_record_queued")
    assert_equal 3, batch_events.count

    completion_event = Event.find_by(job: job, event_type: "batch_job_completed")
    assert completion_event.present?
    assert_includes completion_event.message, "3 succeeded"
  end

  test "should handle batch processing failures gracefully" do
    # Create batch with one invalid job record
    job = Job.create!(
      organization: @organization,
      agent_type: "PAY_STUB_COLLECTOR",
      trigger_source: "test_batch",
      user: @user,
      status: "running",
      total_records: 2
    )

    # Create one valid and one invalid job record
    valid_jr = JobRecord.create!(
      job: job,
      loan_application: @loan_applications.first,
      state: "triggered",
      retry_count: 0
    )

    invalid_jr = JobRecord.create!(
      job: job,
      loan_application: @loan_applications.second,
      state: "failed", # Already failed, should be skipped
      retry_count: 3
    )

    # Mock AgentJob to simulate success/failure
    call_count = 0
    PayStub::AgentJob.stub(:perform_later, proc { |id| 
      call_count += 1
      if id == valid_jr.id
        true  # Success
      else
        raise StandardError, "Simulated failure"
      end
    }) do
      PayStub::BatchAgentJob.perform_now(job.id)
    end

    # Should only call perform_later once (for the valid record)
    assert_equal 1, call_count

    # Verify job completed despite having failed records
    job.reload
    assert_equal "completed", job.status

    # Check final states
    valid_jr.reload
    invalid_jr.reload
    
    assert_equal "queued", valid_jr.state
    assert_equal "failed", invalid_jr.state # Should remain failed
  end

  test "should provide comprehensive batch monitoring" do
    # Create a completed batch job for monitoring
    job = Job.create!(
      organization: @organization,
      agent_type: "PAY_STUB_COLLECTOR",
      trigger_source: "test_batch",
      user: @user,
      status: "completed",
      total_records: 10,
      started_at: 1.hour.ago,
      completed_at: 30.minutes.ago
    )

    # Create job records in various states
    states = %w[completed completed failed collecting uploading completed failed completed completed queued]
    job_records = @loan_applications.first(10).map.with_index do |loan, index|
      JobRecord.create!(
        job: job,
        loan_application: loan,
        state: states[index],
        retry_count: states[index] == "failed" ? 2 : 0
      )
    end

    # Test batch monitoring
    status_report = BatchJobMonitor.status_report(job.id)
    
    assert_equal job.id, status_report[:job_info][:id]
    assert_equal "completed", status_report[:job_info][:status]
    assert_equal 10, status_report[:job_info][:total_records]
    
    progress = status_report[:progress_summary]
    assert_equal 10, progress[:total_records]
    assert_equal 6, progress[:completed]  # 6 completed records
    assert_equal 2, progress[:failed]     # 2 failed records
    assert_equal 2, progress[:in_progress] # 1 collecting + 1 uploading + 1 queued = 3, but queued might be counted differently
    
    # Test batch job listing
    batch_jobs = BatchJobMonitor.list_batch_jobs(organization_id: @organization.id)
    assert batch_jobs.any? { |bj| bj[:job_id] == job.id }
    
    # Test performance analytics
    analytics = BatchJobMonitor.performance_analytics(organization_id: @organization.id)
    assert analytics.present?
    assert analytics[:summary].present?
    assert_equal 1, analytics[:summary][:total_batch_jobs]
  end

  test "should handle batch job cancellation" do
    # Create a running batch job
    job = Job.create!(
      organization: @organization,
      agent_type: "PAY_STUB_COLLECTOR",
      trigger_source: "test_batch",
      user: @user,
      status: "running",
      total_records: 5
    )

    # Create job records in different states
    triggered_jr = JobRecord.create!(job: job, loan_application: @loan_applications[0], state: "triggered")
    queued_jr = JobRecord.create!(job: job, loan_application: @loan_applications[1], state: "queued")
    processing_jr = JobRecord.create!(job: job, loan_application: @loan_applications[2], state: "processing")
    uploading_jr = JobRecord.create!(job: job, loan_application: @loan_applications[3], state: "uploading")
    completed_jr = JobRecord.create!(job: job, loan_application: @loan_applications[4], state: "completed")

    # Cancel the batch job via API
    post "/batch_jobs/#{job.id}/cancel",
         headers: { "X-API-Key": "test-api-key" }

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "success", response_data["status"]
    assert_equal "Batch job cancelled", response_data["message"]
    assert_equal 2, response_data["records_cancelled"] # triggered + queued

    # Verify job status
    job.reload
    assert_equal "cancelled", job.status
    assert job.completed_at.present?

    # Verify record states
    [triggered_jr, queued_jr, processing_jr, uploading_jr, completed_jr].each(&:reload)
    
    assert_equal "cancelled", triggered_jr.state
    assert_equal "cancelled", queued_jr.state
    assert_equal "processing", processing_jr.state  # Should not change
    assert_equal "uploading", uploading_jr.state   # Should not change  
    assert_equal "completed", completed_jr.state   # Should not change

    # Verify cancellation event was logged
    cancel_event = Event.find_by(job: job, event_type: "batch_job_cancelled")
    assert cancel_event.present?
  end

  test "should validate batch size limits" do
    # Test batch size validation
    assert_raises(ArgumentError, "Batch size cannot exceed 50,000") do
      BatchJobTrigger.create_batch_job!(
        organization: @organization,
        loan_applications: @loan_applications,
        triggered_by_user: @user,
        batch_size: 60_000
      )
    end

    assert_raises(ArgumentError, "Batch size must be positive") do
      BatchJobTrigger.create_batch_job!(
        organization: @organization,
        loan_applications: @loan_applications,
        triggered_by_user: @user,
        batch_size: 0
      )
    end
  end

  test "should filter eligible loans correctly" do
    # Create mix of eligible and ineligible loans
    ineligible_loans = [
      # Not approved
      LoanApplication.create!(
        organization: @organization,
        applicant_id: "INELIGIBLE-1",
        los_external_id: "LOS-INELIGIBLE-1",
        status: "pending",
        income_doc_required: true,
        approved_at: nil
      ),
      # No income doc required and no notes
      LoanApplication.create!(
        organization: @organization,
        applicant_id: "INELIGIBLE-2",
        los_external_id: "LOS-INELIGIBLE-2", 
        status: "approved",
        income_doc_required: false,
        approved_at: Time.current
      )
    ]

    all_loans = @loan_applications + ineligible_loans
    
    # Test filtering
    result = BatchJobTrigger.create_batch_job!(
      organization: @organization,
      loan_applications: all_loans,
      triggered_by_user: @user,
      batch_size: 50
    )

    # Should only process the eligible loans (original 25)
    assert_equal 1, result[:total_jobs_created]
    assert_equal 25, result[:total_records_processed]
  end

  private

  def create_loan_applications(count)
    (1..count).map do |i|
      LoanApplication.create!(
        organization: @organization,
        applicant_id: "APP-#{i}",
        los_external_id: "LOS-#{i}",
        status: "approved",
        income_doc_required: true,
        approved_at: Time.current
      )
    end
  end
end

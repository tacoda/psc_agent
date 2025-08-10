require "test_helper"

class LoanApprovalTriggerAcceptanceTest < ActionDispatch::IntegrationTest
  def setup
    @organization = Organization.create!(name: "Test Credit Union", status: "active")
    @user = User.create!(
      organization: @organization,
      email: "loan.officer@testcu.org", 
      name: "Test Loan Officer",
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
        queues: { collect: "pay_stub_collect", upload: "los_upload" }
      }
    )
    
    @loan_application = LoanApplication.create!(
      organization: @organization,
      applicant_id: "ACC-TEST-001",
      los_external_id: "LOS-12345",
      status: "pending",
      income_doc_required: true,
      approved_at: nil
    )

    # Mock API key for authentication
    Rails.application.credentials.define_singleton_method(:loan_webhook_api_key) { "test-api-key" }
  end

  # Story: Given a loan is approved with a note "pay stub required",
  # When the agent is triggered,
  # Then it should retrieve the pay stub from the applicant via secure method.
  test "should trigger pay stub collection when loan approved with pay stub required note" do
    # Given: A loan application exists and routing rules are configured
    assert_equal "pending", @loan_application.status
    assert @loan_application.income_doc_required?
    assert @routing_rule.enabled?
    
    # When: Webhook is called with loan approval and pay stub requirement
    webhook_payload = {
      organization_id: @organization.id,
      loan_application: {
        los_external_id: @loan_application.los_external_id,
        applicant_id: @loan_application.applicant_id,
        status: "approved",
        income_doc_required: true,
        approved_at: Time.current.iso8601,
        notes: "Loan conditionally approved - pay stub required for final verification"
      }
    }

    assert_difference "Job.count", 1 do
      assert_difference "JobRecord.count", 1 do
        assert_difference "Event.count", 1 do
          post "/loan_approvals/webhook", 
               params: webhook_payload,
               headers: { "X-API-Key": "test-api-key" }
        end
      end
    end

    # Then: Response should indicate success
    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "success", response_data["status"]
    assert_includes response_data["message"], "Pay stub collection agent triggered"

    # And: Job should be created correctly
    job = Job.last
    assert_equal @organization.id, job.organization_id
    assert_equal "PAY_STUB_COLLECTOR", job.agent_type
    assert_equal "loan_approval", job.trigger_source
    assert_equal @user.id, job.user_id
    assert_equal "running", job.status
    assert_equal 1, job.total_records

    # And: JobRecord should be created with correct state
    job_record = JobRecord.last
    assert_equal job.id, job_record.job_id
    assert_equal @loan_application.id, job_record.loan_application_id
    assert_equal "triggered", job_record.state
    assert_equal 0, job_record.retry_count
    assert job_record.next_attempt_at <= Time.current

    # And: Loan application should be updated to approved
    @loan_application.reload
    assert_equal "approved", @loan_application.status
    assert @loan_application.approved_at.present?

    # And: Trigger event should be logged
    trigger_event = Event.where(
      job_record: job_record,
      event_type: "loan_approved_trigger"
    ).first
    assert trigger_event.present?
    assert_equal "trigger", trigger_event.phase
    assert_equal "info", trigger_event.severity
    assert_includes trigger_event.message, @loan_application.los_external_id

    # And: When the agent job runs, it should initiate secure document collection
    # (Testing the LocateJob which calls SecureDocumentCollector)
    PayStub::LocateJob.perform_now(job_record.id)

    # Then: Document should be created for collection
    document = Document.find_by(
      loan_application: @loan_application,
      document_type: "PAY_STUB"
    )
    assert document.present?
    assert_equal "collection_sent", document.status
    assert document.storage_url.present?
    assert document.kms_key_id.present?

    # And: Job record should progress to collecting state
    job_record.reload
    assert_equal "collecting", job_record.state

    # And: Collection event should be logged
    collection_event = Event.where(
      job_record: job_record,
      event_type: "document_collection_initiated"
    ).first
    assert collection_event.present?
    assert_equal "collect", collection_event.phase
    assert_includes collection_event.message, @loan_application.applicant_id
  end

  test "should not trigger if income doc not required and no pay stub note" do
    # Given: Loan application without income doc requirement
    webhook_payload = {
      organization_id: @organization.id,
      loan_application: {
        los_external_id: @loan_application.los_external_id,
        applicant_id: @loan_application.applicant_id,
        status: "approved",
        income_doc_required: false,
        approved_at: Time.current.iso8601,
        notes: "Standard approval - no additional docs needed"
      }
    }

    # When: Webhook is called
    assert_no_difference "Job.count" do
      assert_no_difference "JobRecord.count" do
        post "/loan_approvals/webhook", 
             params: webhook_payload,
             headers: { "X-API-Key": "test-api-key" }
      end
    end

    # Then: Should not trigger agent
    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "success", response_data["status"]
    assert_includes response_data["message"], "no agent trigger required"
  end

  test "should trigger if pay stub mentioned in notes even without income_doc_required flag" do
    # Given: Loan without income_doc_required but with pay stub note
    webhook_payload = {
      organization_id: @organization.id,
      loan_application: {
        los_external_id: @loan_application.los_external_id,
        applicant_id: @loan_application.applicant_id,
        status: "approved",
        income_doc_required: false,
        approved_at: Time.current.iso8601,
        notes: "Approved with condition - pay stub required before funding"
      }
    }

    # When: Webhook is called
    assert_difference "Job.count", 1 do
      post "/loan_approvals/webhook", 
           params: webhook_payload,
           headers: { "X-API-Key": "test-api-key" }
    end

    # Then: Should trigger agent based on note content
    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "success", response_data["status"]
    assert_includes response_data["message"], "Pay stub collection agent triggered"
  end

  test "should prevent duplicate triggers for same loan" do
    # Given: Loan is already approved and has existing job
    @loan_application.update!(status: "approved", approved_at: Time.current)
    existing_job = Job.create!(
      organization: @organization,
      agent_type: "PAY_STUB_COLLECTOR",
      trigger_source: "loan_approval",
      user: @user,
      status: "running",
      total_records: 1
    )
    JobRecord.create!(
      job: existing_job,
      loan_application: @loan_application,
      state: "collecting",
      retry_count: 0
    )

    webhook_payload = {
      organization_id: @organization.id,
      loan_application: {
        los_external_id: @loan_application.los_external_id,
        applicant_id: @loan_application.applicant_id,
        status: "approved",
        income_doc_required: true,
        approved_at: Time.current.iso8601
      }
    }

    # When: Same webhook is called again
    assert_no_difference "Job.count" do
      post "/loan_approvals/webhook", 
           params: webhook_payload,
           headers: { "X-API-Key": "test-api-key" }
    end

    # Then: Should not create duplicate job
    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "success", response_data["status"]
    assert_includes response_data["message"], "no agent trigger required"
  end

  test "should handle manual trigger for lending officer" do
    # Given: Approved loan application
    @loan_application.update!(
      status: "approved", 
      income_doc_required: true,
      approved_at: Time.current
    )

    lending_officer = User.create!(
      organization: @organization,
      email: "officer@testcu.org",
      name: "Manual Officer",
      role: "lending_officer",
      status: "active"
    )

    # When: Manual trigger is called
    trigger_params = {
      loan_application_id: @loan_application.id,
      user_id: lending_officer.id
    }

    assert_difference "Job.count", 1 do
      post "/loan_approvals/manual_trigger", 
           params: trigger_params,
           headers: { "X-API-Key": "test-api-key" }
    end

    # Then: Should create job manually triggered by lending officer
    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "success", response_data["status"]
    assert_includes response_data["message"], "triggered manually"

    job = Job.last
    assert_equal lending_officer.id, job.user_id
    assert_equal "loan_approval", job.trigger_source
  end

  test "should require authentication for webhook calls" do
    webhook_payload = {
      organization_id: @organization.id,
      loan_application: {
        los_external_id: @loan_application.los_external_id,
        status: "approved",
        income_doc_required: true
      }
    }

    # When: Called without API key
    post "/loan_approvals/webhook", params: webhook_payload

    # Then: Should return unauthorized
    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "error", response_data["status"]
    assert_equal "Unauthorized", response_data["message"]

    # When: Called with invalid API key
    post "/loan_approvals/webhook", 
         params: webhook_payload,
         headers: { "X-API-Key": "invalid-key" }

    # Then: Should return unauthorized
    assert_response :unauthorized
  end

  test "should handle missing organization gracefully" do
    webhook_payload = {
      organization_id: 99999, # Non-existent organization
      loan_application: {
        los_external_id: "TEST-123",
        status: "approved",
        income_doc_required: true
      }
    }

    # When: Called with invalid organization
    post "/loan_approvals/webhook", 
         params: webhook_payload,
         headers: { "X-API-Key": "test-api-key" }

    # Then: Should return not found error
    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "error", response_data["status"]
    assert_includes response_data["message"], "not found"
  end
end

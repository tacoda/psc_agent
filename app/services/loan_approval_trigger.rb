class LoanApprovalTrigger
  class << self
    # Trigger the pay stub collector agent for approved loans requiring income docs
    def call!(loan_application:, triggered_by_user:, notes: nil)
      return unless should_trigger?(loan_application, notes)

      organization = loan_application.organization
      routing_rule = find_routing_rule(organization)
      
      raise "No active routing rule found for organization #{organization.id}" unless routing_rule

      # Create a job batch for this trigger
      job = Job.create!(
        organization: organization,
        agent_type: "PAY_STUB_COLLECTOR",
        trigger_source: "loan_approval",
        user: triggered_by_user,
        status: "running",
        total_records: 1
      )

      # Create job record for this specific loan application
      job_record = JobRecord.create!(
        job: job,
        loan_application: loan_application,
        state: "triggered",
        retry_count: 0,
        next_attempt_at: Time.current,
        last_error_code: nil,
        last_error_msg: nil
      )

      # Log the trigger event
      Event.create!(
        organization: organization,
        user: triggered_by_user,
        job: job,
        job_record: job_record,
        event_type: "loan_approved_trigger",
        phase: "trigger",
        severity: "info",
        message: "Pay stub collection triggered for loan #{loan_application.los_external_id}",
        ts: Time.current,
        trace_id: SecureRandom.hex(10)
      )

      # Queue the pay stub collection agent
      queue_name = routing_rule.criteria_json.dig("queues", "collect") || "pay_stub_collect"
      PayStub::AgentJob.set(queue: queue_name).perform_later(job_record.id)

      {
        job: job,
        job_record: job_record,
        message: "Pay stub collection agent triggered successfully"
      }
    end

    private

    def should_trigger?(loan_application, notes = nil)
      # Check for pay stub requirement in notes
      pay_stub_in_notes = notes && notes.downcase.include?("pay stub required")
      
      loan_application.status == "approved" &&
        (loan_application.income_doc_required? || pay_stub_in_notes) &&
        loan_application.approved_at.present?
    end

    def find_routing_rule(organization)
      organization.routing_rules
                  .where(enabled: true)
                  .where("criteria_json ->> 'trigger' = ?", "loan_approved")
                  .where("criteria_json ->> 'requires_income_doc' = ?", "true")
                  .first
    end
  end
end

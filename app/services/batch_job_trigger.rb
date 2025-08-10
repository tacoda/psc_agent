class BatchJobTrigger
  class << self
    # Create a batch job for multiple loan applications
    # @param organization [Organization] The organization these loans belong to
    # @param loan_applications [Array<LoanApplication>, ActiveRecord::Relation] Loan applications to process
    # @param triggered_by_user [User] User who triggered this batch
    # @param batch_size [Integer] Maximum records per job (default: 10,000)
    # @param trigger_source [String] Source of the trigger (default: "batch_approval")
    def create_batch_job!(organization:, loan_applications:, triggered_by_user:, batch_size: 10_000, trigger_source: "batch_approval")
      validate_inputs!(organization, loan_applications, triggered_by_user, batch_size)
      
      routing_rule = find_routing_rule(organization)
      raise "No active routing rule found for organization #{organization.id}" unless routing_rule

      total_loans = loan_applications.is_a?(Array) ? loan_applications.count : loan_applications.count
      Rails.logger.info "Creating batch jobs for #{total_loans} loan applications with batch size #{batch_size}"

      created_jobs = []
      processed_count = 0

      # Process loans in batches
      if loan_applications.respond_to?(:find_in_batches)
        loan_applications.find_in_batches(batch_size: batch_size) do |batch|
          process_batch(batch, organization, triggered_by_user, trigger_source, routing_rule, created_jobs, processed_count, total_loans, batch_size)
          processed_count += batch.size
        end
      else
        # Handle Arrays by using each_slice
        loan_applications.each_slice(batch_size) do |batch|
          process_batch(batch, organization, triggered_by_user, trigger_source, routing_rule, created_jobs, processed_count, total_loans, batch_size)
          processed_count += batch.size
        end
      end

      {
        total_jobs_created: created_jobs.size,
        total_records_processed: processed_count,
        jobs: created_jobs,
        message: "Created #{created_jobs.size} batch job(s) for #{processed_count} loan applications"
      }
    end

    def process_batch(batch, organization, triggered_by_user, trigger_source, routing_rule, created_jobs, processed_count, total_loans, batch_size)
      job = create_job_for_batch(
        organization: organization,
        triggered_by_user: triggered_by_user,
        trigger_source: trigger_source,
        batch_size: batch.size,
        batch_number: (processed_count / batch_size) + 1
      )

      # Create job records for each loan in this batch
      job_records = create_job_records_for_batch(job, batch)

      # Log the batch creation event
      log_batch_creation_event(organization, triggered_by_user, job, batch)

      # Queue the batch processing job
      queue_name = routing_rule.criteria_json.dig("queues", "batch_collect") || 
                   routing_rule.criteria_json.dig("queues", "collect") || 
                   "pay_stub_batch"
      
      PayStub::BatchAgentJob.set(queue: queue_name).perform_later(job.id)

      created_jobs << {
        job: job,
        job_records: job_records,
        queue: queue_name
      }

      Rails.logger.info "Created batch job #{job.id} with #{batch.size} records (#{processed_count + batch.size}/#{total_loans} total)"
    end

    # Create batch jobs from a list of loan application IDs
    # Useful for webhook endpoints that receive arrays of loan IDs
    def create_batch_job_from_ids!(organization:, loan_application_ids:, triggered_by_user:, batch_size: 10_000, trigger_source: "batch_approval")
      # Get all the specified loan applications
      all_loan_applications = organization.loan_applications.where(id: loan_application_ids)
      
      # Filter for eligible loans (approved and requiring income docs)
      eligible_loans = all_loan_applications.select do |loan|
        loan.status == "approved" && loan.income_doc_required? && !already_triggered?(loan)
      end

      if eligible_loans.empty?
        return {
          total_jobs_created: 0,
          total_records_processed: 0,
          jobs: [],
          message: "No eligible loan applications found for batch processing"
        }
      end

      create_batch_job!(
        organization: organization,
        loan_applications: eligible_loans,
        triggered_by_user: triggered_by_user,
        batch_size: batch_size,
        trigger_source: trigger_source
      )
    end

    # Check if loan applications should trigger pay stub collection based on criteria
    def filter_eligible_loans(loan_applications)
      loan_applications.select do |loan|
        should_trigger_for_loan?(loan)
      end
    end

    private

    def validate_inputs!(organization, loan_applications, triggered_by_user, batch_size)
      raise ArgumentError, "Organization cannot be nil" unless organization
      raise ArgumentError, "Loan applications cannot be nil" unless loan_applications
      raise ArgumentError, "Triggered by user cannot be nil" unless triggered_by_user
      raise ArgumentError, "Batch size must be positive" unless batch_size > 0
      raise ArgumentError, "Batch size cannot exceed 50,000" if batch_size > 50_000

      unless triggered_by_user.organization_id == organization.id
        raise ArgumentError, "User does not belong to the specified organization"
      end
    end

    def find_routing_rule(organization)
      organization.routing_rules
                  .where(enabled: true)
                  .where("criteria_json ->> 'trigger' = ?", "loan_approved")
                  .where("criteria_json ->> 'requires_income_doc' = ?", "true")
                  .first
    end

    def should_trigger_for_loan?(loan_application)
      return false unless loan_application.status == "approved"
      return false unless loan_application.approved_at.present?
      return false if already_triggered?(loan_application)
      
      # Check if income doc is required or if there are notes indicating pay stub required
      loan_application.income_doc_required? || has_pay_stub_requirement_in_notes?(loan_application)
    end

    def has_pay_stub_requirement_in_notes?(loan_application)
      # Check recent events for pay stub requirements
      Event.where(
        organization_id: loan_application.organization_id,
        message: Event.arel_table[:message].matches('%pay stub required%')
      ).where(
        "created_at >= ?", 24.hours.ago
      ).exists?
    end

    def already_triggered?(loan_application)
      JobRecord.joins(:job)
               .where(loan_application: loan_application)
               .where(jobs: { agent_type: "PAY_STUB_COLLECTOR" })
               .where.not(jobs: { status: ["completed", "failed"] })
               .exists?
    end

    def create_job_for_batch(organization:, triggered_by_user:, trigger_source:, batch_size:, batch_number:)
      Job.create!(
        organization: organization,
        agent_type: "PAY_STUB_COLLECTOR",
        trigger_source: trigger_source,
        user: triggered_by_user,
        status: "running",
        total_records: batch_size,
        created_at: Time.current,
        started_at: Time.current
      )
    end

    def create_job_records_for_batch(job, loan_applications_batch)
      job_records = []
      
      loan_applications_batch.each do |loan_application|
        job_record = JobRecord.create!(
          job: job,
          loan_application: loan_application,
          state: "triggered",
          retry_count: 0,
          next_attempt_at: Time.current,
          last_error_code: nil,
          last_error_msg: nil
        )
        job_records << job_record
      end

      job_records
    end

    def log_batch_creation_event(organization, triggered_by_user, job, loan_applications_batch)
      Event.create!(
        organization_id: organization.id,
        user_id: triggered_by_user.id,
        job_id: job.id,
        job_record_id: nil, # This is a job-level event, not specific to one record
        event_type: "batch_job_created",
        phase: "trigger",
        severity: "info",
        message: "Batch job created for #{loan_applications_batch.size} loan applications",
        ts: Time.current,
        trace_id: SecureRandom.hex(10)
      )
    end
  end
end

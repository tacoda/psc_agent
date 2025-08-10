module PayStub
  class RetryFailedUploadsJob < ApplicationJob
    queue_as :pay_stub_retry
    
    # This job runs periodically to check for failed uploads that should be retried
    def perform
      Rails.logger.info "Checking for failed uploads that need retry..."
      
      # Find job records that are eligible for retry
      retry_candidates = JobRecord.joins(:job)
                                  .where(jobs: { agent_type: "PAY_STUB_COLLECTOR" })
                                  .where(state: ["uploading", "failed"])
                                  .where("next_attempt_at <= ?", Time.current)
                                  .where("retry_count < ?", max_retry_attempts)
                                  .includes(:job, :loan_application, :rpa_uploads)

      Rails.logger.info "Found #{retry_candidates.count} job records eligible for retry"

      retry_candidates.find_each do |job_record|
        begin
          process_retry_candidate(job_record)
        rescue StandardError => e
          Rails.logger.error "Error processing retry for job_record #{job_record.id}: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
        end
      end
    end

    private

    def process_retry_candidate(job_record)
      Rails.logger.info "Processing retry candidate: job_record #{job_record.id}"
      
      # Check if document is ready for retry
      document = Document.find_by(loan_application: job_record.loan_application, document_type: "PAY_STUB")
      unless document&.status == "received"
        Rails.logger.warn "Skipping retry for job_record #{job_record.id} - document not ready (status: #{document&.status})"
        return
      end

      # Check organization's routing rules to determine retry queue
      organization = job_record.job.organization
      routing_rule = find_upload_routing_rule(organization)
      
      unless routing_rule
        Rails.logger.error "No upload routing rule found for organization #{organization.id}"
        escalate_no_routing_rule(job_record)
        return
      end

      retry_queue = routing_rule.criteria_json.dig("queues", "upload") || "los_upload"
      
      # Update job record state
      job_record.update!(
        state: "retry_scheduled",
        next_attempt_at: nil
      )

      # Log retry event
      Event.create!(
        organization_id: job_record.job.organization_id,
        user_id: job_record.job.user_id,
        job_id: job_record.job_id,
        job_record_id: job_record.id,
        event_type: "upload_retry_scheduled",
        phase: "upload",
        severity: "info",
        message: "Retry #{job_record.retry_count + 1} scheduled for RPA upload",
        ts: Time.current,
        trace_id: SecureRandom.hex(10)
      )

      # Queue the retry
      ExecuteJob.set(queue: retry_queue).perform_later(job_record.id)
      
      Rails.logger.info "Retry queued for job_record #{job_record.id} on queue #{retry_queue}"
    end

    def find_upload_routing_rule(organization)
      organization.routing_rules
                  .where(enabled: true)
                  .where("criteria_json ->> 'trigger' = ?", "loan_approved")
                  .where("criteria_json ->> 'requires_income_doc' = ?", "true")
                  .first
    end

    def escalate_no_routing_rule(job_record)
      Rails.logger.error "Escalating job_record #{job_record.id} due to missing routing rule"
      
      job_record.update!(
        state: "failed",
        last_error_code: "missing_routing_rule",
        last_error_msg: "No active routing rule found for upload retry"
      )

      Notifications::EscalateFailure.call!(job_record: job_record)
    end

    def max_retry_attempts
      RetryPolicy.find_by(name: "default")&.max_attempts || 3
    end
  end
end

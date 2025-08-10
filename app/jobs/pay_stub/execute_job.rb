module PayStub
  class ExecuteJob < BaseJob
    # Override retry policy for RPA uploads - use custom error handling
    discard_on RpaUploadService::NonRetryableError
    retry_on RpaUploadService::RetryableError, attempts: 3, wait: ->(executions) { executions ** 2 }

    def perform(job_record_id)
      jr = job_record or raise "JobRecord not found"
      doc = Document.find_by!(loan_application_id: jr.loan_application_id, document_type: "PAY_STUB")

      # Validate document is ready for upload
      unless doc.status == "received"
        Rails.logger.error "Cannot upload document #{doc.id} - status is #{doc.status}, expected 'received'"
        raise RpaUploadService::DocumentFormatError, "Document not ready for upload - status: #{doc.status}"
      end

      # Create agent run to track this execution
      run = AgentRun.create!(
        job_record: jr, 
        phase: "upload", 
        status: "in_progress",
        started_at: Time.current, 
        worker_id: "rpa-worker-#{SecureRandom.hex(3)}",
        idempotency_key: SecureRandom.uuid
      )

      begin
        # Use the comprehensive RPA upload service
        result = RpaUploadService.upload_document!(job_record: jr, document: doc)
        
        # Update agent run on success
        run.update!(
          status: "succeeded", 
          ended_at: Time.current
        )
        
        Rails.logger.info "RPA upload completed successfully: #{result[:message]}"
        Rails.logger.info "LOS Document ID: #{result[:los_document_id]}"
        
      rescue RpaUploadService::NonRetryableError => e
        # Update agent run and don't retry
        run.update!(
          status: "failed", 
          ended_at: Time.current
        )
        
        Rails.logger.error "Non-retryable RPA upload error: #{e.message}"
        raise # Re-raise to trigger discard_on
        
      rescue RpaUploadService::RetryableError => e
        # Update agent run and allow retry
        run.update!(
          status: "failed", 
          ended_at: Time.current
        )
        
        Rails.logger.warn "Retryable RPA upload error (attempt #{jr.retry_count + 1}): #{e.message}"
        raise # Re-raise to trigger retry_on
        
      rescue StandardError => e
        # Handle unexpected errors
        run.update!(
          status: "failed", 
          ended_at: Time.current
        )
        
        Rails.logger.error "Unexpected error in RPA upload: #{e.class} - #{e.message}"
        
        # Wrap as retryable error
        wrapped_error = RpaUploadService::RetryableError.new("Unexpected RPA error: #{e.message}")
        wrapped_error.set_backtrace(e.backtrace)
        raise wrapped_error
      end
    end
  end
end

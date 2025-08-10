class RpaUploadService
  # Custom error classes for different failure scenarios
  class RpaError < StandardError; end
  class RetryableError < RpaError; end
  class NonRetryableError < RpaError; end
  class LosTimeoutError < RetryableError; end
  class LosAuthenticationError < RetryableError; end
  class DocumentFormatError < NonRetryableError; end
  class LosSystemError < RetryableError; end

  class << self
    # Main entry point for RPA upload
    def upload_document!(job_record:, document:)
      validate_prerequisites!(job_record, document)

      attempt_number = job_record.retry_count + 1
      los_session_id = generate_session_id

      # Create RPA upload record to track this attempt
      rpa_upload = create_upload_record!(
        job_record: job_record,
        document: document,
        attempt: attempt_number,
        session_id: los_session_id
      )

      begin
        # Perform the actual RPA upload
        upload_result = perform_rpa_upload!(
          rpa_upload: rpa_upload,
          document: document,
          session_id: los_session_id
        )

        # Handle successful upload
        handle_upload_success!(
          rpa_upload: rpa_upload,
          job_record: job_record,
          document: document,
          result: upload_result
        )

        log_success_event!(job_record, document, rpa_upload, upload_result)
        
        {
          success: true,
          rpa_upload: rpa_upload,
          los_document_id: upload_result[:los_document_id],
          message: "Document uploaded successfully to LOS"
        }

      rescue NonRetryableError => e
        # Handle non-retryable errors (don't retry)
        handle_upload_failure!(
          rpa_upload: rpa_upload,
          job_record: job_record,
          error: e,
          retryable: false
        )

        log_failure_event!(job_record, document, rpa_upload, e, retryable: false)
        
        raise e # Re-raise to stop job processing

      rescue RetryableError => e
        # Handle retryable errors (will retry based on policy)
        handle_upload_failure!(
          rpa_upload: rpa_upload,
          job_record: job_record,
          error: e,
          retryable: true
        )

        log_failure_event!(job_record, document, rpa_upload, e, retryable: true)
        
        # Check if we should retry or escalate
        if should_retry?(job_record)
          schedule_retry!(job_record)
          raise e # Re-raise to trigger job retry
        else
          escalate_to_human!(job_record, e)
          raise e
        end
        
      rescue StandardError => e
        # Handle unexpected errors as retryable
        wrapped_error = RetryableError.new("Unexpected RPA error: #{e.message}")
        wrapped_error.set_backtrace(e.backtrace)
        
        handle_upload_failure!(
          rpa_upload: rpa_upload,
          job_record: job_record,
          error: wrapped_error,
          retryable: true
        )

        log_failure_event!(job_record, document, rpa_upload, wrapped_error, retryable: true)
        
        if should_retry?(job_record)
          schedule_retry!(job_record)
          raise wrapped_error
        else
          escalate_to_human!(job_record, wrapped_error)
          raise wrapped_error
        end
      end
    end

    private

    def validate_prerequisites!(job_record, document)
      raise ArgumentError, "JobRecord cannot be nil" unless job_record
      raise ArgumentError, "Document cannot be nil" unless document
      raise DocumentFormatError, "Document not in received status" unless document.status == "received"
      raise DocumentFormatError, "Document file not available" unless document.storage_url.present?
      raise DocumentFormatError, "Document missing SHA256 checksum" unless document.sha256.present?
    end

    def generate_session_id
      "rpa_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(6)}"
    end

    def create_upload_record!(job_record:, document:, attempt:, session_id:)
      RpaUpload.create!(
        job_record: job_record,
        document: document,
        los_session_id: session_id,
        status: "in_progress",
        attempt: attempt,
        started_at: Time.current,
        ended_at: nil,
        error_code: nil,
        error_msg: nil
      )
    end

    def perform_rpa_upload!(rpa_upload:, document:, session_id:)
      Rails.logger.info "Starting RPA upload for session #{session_id}"
      
      # Step 1: Initialize RPA session
      rpa_session = initialize_rpa_session(session_id)
      
      # Step 2: Authenticate with LOS
      authenticate_with_los!(rpa_session, rpa_upload.job_record.loan_application)
      
      # Step 3: Navigate to document upload screen
      navigate_to_upload_screen!(rpa_session, rpa_upload.job_record.loan_application)
      
      # Step 4: Download document from secure storage
      document_data = download_document_securely!(document)
      
      # Step 5: Upload document to LOS
      upload_result = upload_to_los!(rpa_session, document_data, document)
      
      # Step 6: Verify upload was successful
      verification_result = verify_upload!(rpa_session, upload_result[:los_document_id])
      
      # Step 7: Clean up RPA session
      cleanup_rpa_session(rpa_session)
      
      {
        los_document_id: upload_result[:los_document_id],
        verification_status: verification_result[:status],
        upload_timestamp: Time.current,
        session_id: session_id
      }
    end

    def initialize_rpa_session(session_id)
      # In production, this would initialize the actual RPA framework
      # (e.g., Selenium WebDriver, UiPath, Blue Prism, etc.)
      Rails.logger.info "Initializing RPA session: #{session_id}"
      
      # Simulate session initialization
      {
        session_id: session_id,
        browser: "chrome_headless",
        started_at: Time.current,
        status: "active"
      }
    end

    def authenticate_with_los!(session, loan_application)
      Rails.logger.info "Authenticating with LOS for organization #{loan_application.organization_id}"
      
      # Simulate potential authentication failures
      if rand < 0.1 # 10% chance of auth failure
        raise LosAuthenticationError, "Failed to authenticate with LOS system"
      end
      
      # Simulate timeout
      if rand < 0.05 # 5% chance of timeout
        raise LosTimeoutError, "Timeout during LOS authentication"
      end
      
      Rails.logger.info "LOS authentication successful"
    end

    def navigate_to_upload_screen!(session, loan_application)
      Rails.logger.info "Navigating to document upload screen for loan #{loan_application.los_external_id}"
      
      # Simulate navigation issues
      if rand < 0.08 # 8% chance of navigation failure
        raise LosSystemError, "Could not navigate to document upload screen"
      end
      
      Rails.logger.info "Successfully navigated to upload screen"
    end

    def download_document_securely!(document)
      Rails.logger.info "Downloading document from secure storage: #{document.storage_url}"
      
      # In production, this would:
      # 1. Use AWS SDK to download from S3 with proper credentials
      # 2. Decrypt using KMS key
      # 3. Verify SHA256 checksum
      # 4. Return decrypted document data
      
      # Simulate download failure
      if rand < 0.02 # 2% chance of download failure
        raise RetryableError, "Failed to download document from secure storage"
      end
      
      # Simulate document data
      {
        content: "PDF_CONTENT_PLACEHOLDER_#{document.id}",
        filename: "paystub_#{document.id}.pdf",
        content_type: "application/pdf",
        size: document.size_bytes
      }
    end

    def upload_to_los!(session, document_data, document)
      Rails.logger.info "Uploading document to LOS system"
      
      # Simulate various upload failures
      failure_rand = rand
      
      if failure_rand < 0.15 # 15% chance of timeout
        raise LosTimeoutError, "Upload timeout - LOS system did not respond"
      elsif failure_rand < 0.25 # 10% additional chance of system error  
        raise LosSystemError, "LOS system error during upload"
      elsif failure_rand < 0.27 # 2% chance of format error
        raise DocumentFormatError, "LOS rejected document format"
      end
      
      # Successful upload
      los_document_id = "LOS_DOC_#{SecureRandom.alphanumeric(8)}"
      Rails.logger.info "Document uploaded successfully with LOS ID: #{los_document_id}"
      
      {
        los_document_id: los_document_id,
        upload_timestamp: Time.current,
        file_size: document_data[:size]
      }
    end

    def verify_upload!(session, los_document_id)
      Rails.logger.info "Verifying upload for LOS document ID: #{los_document_id}"
      
      # Simulate verification
      if rand < 0.05 # 5% chance verification fails
        raise LosSystemError, "Upload verification failed"
      end
      
      {
        status: "verified",
        verified_at: Time.current,
        los_document_id: los_document_id
      }
    end

    def cleanup_rpa_session(session)
      Rails.logger.info "Cleaning up RPA session: #{session[:session_id]}"
      # In production: close browser, cleanup temp files, etc.
    end

    def handle_upload_success!(rpa_upload:, job_record:, document:, result:)
      rpa_upload.update!(
        status: "succeeded",
        ended_at: Time.current,
        error_code: nil,
        error_msg: nil
      )

      document.update!(status: "uploaded")
      job_record.update!(state: "uploaded", last_error_code: nil, last_error_msg: nil)
    end

    def handle_upload_failure!(rpa_upload:, job_record:, error:, retryable:)
      error_code = error.class.name.demodulize.underscore
      
      rpa_upload.update!(
        status: "failed",
        ended_at: Time.current,
        error_code: error_code,
        error_msg: error.message
      )

      job_record.update!(
        last_error_code: error_code,
        last_error_msg: error.message
      )

      job_record.increment!(:retry_count) if retryable
    end

    def should_retry?(job_record)
      max_retries = get_max_retries(job_record.job.organization)
      job_record.retry_count < max_retries
    end

    def get_max_retries(organization)
      # Get retry policy from organization or use default
      retry_policy = RetryPolicy.find_by(name: "default")
      retry_policy&.max_attempts || 3
    end

    def schedule_retry!(job_record)
      retry_policy = RetryPolicy.find_by(name: "default")
      base_backoff = retry_policy&.base_backoff_sec || 30
      jitter_pct = retry_policy&.jitter_pct || 25
      
      # Exponential backoff with jitter
      backoff_seconds = base_backoff * (2 ** (job_record.retry_count - 1))
      jitter = backoff_seconds * jitter_pct / 100
      total_delay = backoff_seconds + rand(-jitter..jitter)
      
      next_attempt = Time.current + total_delay.seconds
      job_record.update!(next_attempt_at: next_attempt)
      
      Rails.logger.info "Scheduling retry #{job_record.retry_count} for job_record #{job_record.id} at #{next_attempt}"
    end

    def escalate_to_human!(job_record, error)
      Rails.logger.error "Escalating job_record #{job_record.id} to human after #{job_record.retry_count} retries"
      
      # Use enhanced escalation service with full error context
      Notifications::EscalateRpaFailure.call!(job_record: job_record, final_error: error)
      
      Rails.logger.info "RPA upload failure escalated to lending officers with comprehensive error context"
    end

    def log_success_event!(job_record, document, rpa_upload, result)
      Event.create!(
        organization_id: job_record.job.organization_id,
        user_id: job_record.job.user_id,
        job_id: job_record.job_id,
        job_record_id: job_record.id,
        event_type: "rpa_upload_success",
        phase: "upload",
        severity: "info",
        message: "Document uploaded successfully to LOS. LOS Document ID: #{result[:los_document_id]}",
        ts: Time.current,
        trace_id: SecureRandom.hex(10)
      )
    end

    def log_failure_event!(job_record, document, rpa_upload, error, retryable:)
      severity = retryable ? "warn" : "error"
      retry_info = retryable ? " (attempt #{rpa_upload.attempt}, will retry)" : " (non-retryable)"
      
      Event.create!(
        organization_id: job_record.job.organization_id,
        user_id: job_record.job.user_id,
        job_id: job_record.job_id,
        job_record_id: job_record.id,
        event_type: "rpa_upload_failure",
        phase: "upload",
        severity: severity,
        message: "RPA upload failed: #{error.message}#{retry_info}",
        ts: Time.current,
        trace_id: SecureRandom.hex(10)
      )
    end
  end
end

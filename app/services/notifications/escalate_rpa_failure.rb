module Notifications
  class EscalateRpaFailure
    class << self
      # Main entry point for escalating exhausted RPA upload failures
      def call!(job_record:, final_error: nil)
        validate_job_record!(job_record)
        
        # Gather comprehensive error context
        error_context = build_error_context(job_record, final_error)
        
        # Find appropriate lending officers to notify
        lending_officers = find_lending_officers(job_record.job.organization)
        
        # Create notifications for each lending officer
        notifications = create_notifications!(
          job_record: job_record,
          lending_officers: lending_officers,
          error_context: error_context
        )
        
        # Send immediate email notifications
        send_email_notifications!(notifications, error_context)
        
        # Send SMS if urgent (optional - based on organization settings)
        send_sms_notifications!(notifications, error_context) if should_send_sms?(job_record)
        
        # Create Slack/Teams notification if configured
        send_team_notifications!(job_record, error_context)
        
        # Log the escalation event
        log_escalation_event!(job_record, error_context, notifications)
        
        # Update job record to reflect escalation
        mark_as_escalated!(job_record, error_context)
        
        {
          success: true,
          notifications_created: notifications.size,
          lending_officers_notified: lending_officers.size,
          error_context: error_context,
          message: "RPA upload failure escalated to #{lending_officers.size} lending officers"
        }
      end

      private

      def validate_job_record!(job_record)
        raise ArgumentError, "JobRecord cannot be nil" unless job_record
        raise ArgumentError, "Job not found" unless job_record.job
        raise ArgumentError, "Organization not found" unless job_record.job.organization
        raise ArgumentError, "Loan application not found" unless job_record.loan_application
      end

      def build_error_context(job_record, final_error)
        loan_application = job_record.loan_application
        document = Document.find_by(loan_application: loan_application, document_type: "PAY_STUB")
        rpa_uploads = job_record.rpa_uploads.order(:created_at)
        recent_events = Event.where(job_record: job_record).order(:ts).limit(20)
        
        context = {
          # Job and loan details
          job_record_id: job_record.id,
          job_id: job_record.job_id,
          loan_application: {
            id: loan_application.id,
            applicant_id: loan_application.applicant_id,
            los_external_id: loan_application.los_external_id,
            status: loan_application.status,
            approved_at: loan_application.approved_at
          },
          
          # Retry information
          retry_summary: {
            total_attempts: job_record.retry_count,
            max_attempts_allowed: get_max_retries(job_record.job.organization),
            first_failure_at: rpa_uploads.where(status: "failed").first&.created_at,
            final_failure_at: rpa_uploads.last&.ended_at,
            time_span_hours: calculate_failure_time_span(rpa_uploads)
          },
          
          # Final error details
          final_error: {
            code: job_record.last_error_code,
            message: job_record.last_error_msg,
            error_class: final_error&.class&.name,
            is_retryable: final_error.is_a?(RpaUploadService::RetryableError)
          },
          
          # Document information
          document_info: document ? {
            id: document.id,
            status: document.status,
            size_bytes: document.size_bytes,
            storage_url: document.storage_url&.gsub(/\/[^\/]+$/, "/***"), # Mask filename for security
            created_at: document.created_at
          } : nil,
          
          # Upload attempt history
          upload_attempts: rpa_uploads.map do |upload|
            {
              attempt: upload.attempt,
              status: upload.status,
              started_at: upload.started_at,
              ended_at: upload.ended_at,
              duration_seconds: upload.ended_at ? (upload.ended_at - upload.started_at).round : nil,
              error_code: upload.error_code,
              error_message: upload.error_msg,
              los_session_id: upload.los_session_id
            }
          end,
          
          # Failure pattern analysis
          failure_analysis: analyze_failure_patterns(rpa_uploads),
          
          # Recent events for context
          recent_events: recent_events.map do |event|
            {
              timestamp: event.ts,
              event_type: event.event_type,
              phase: event.phase,
              severity: event.severity,
              message: event.message
            }
          end,
          
          # Escalation metadata
          escalation_info: {
            escalated_at: Time.current,
            escalation_reason: "Automated retries exhausted after #{job_record.retry_count} attempts",
            requires_manual_intervention: true,
            suggested_actions: generate_suggested_actions(job_record, rpa_uploads)
          }
        }
        
        context
      end

      def find_lending_officers(organization)
        # Find all active lending officers in the organization
        lending_officers = organization.users
                                    .where(role: ["lending_officer", "loan_manager", "operations_manager"])
                                    .where(status: "active")
        
        # If no specific lending officers, fall back to any active user
        if lending_officers.empty?
          lending_officers = organization.users.where(status: "active").limit(1)
        end
        
        lending_officers
      end

      def create_notifications!(job_record:, lending_officers:, error_context:)
        notifications = []
        
        lending_officers.each do |officer|
          # Email notification
          email_notification = Notification.create!(
            organization_id: job_record.job.organization_id,
            job_record_id: job_record.id,
            channel: "email",
            user_id: officer.id,
            notification_type: "rpa_upload_failure",
            status: "queued",
            sent_at: nil,
            error_msg: nil
          )
          notifications << email_notification
          
          # SMS notification for urgent cases
          if should_send_sms?(job_record)
            sms_notification = Notification.create!(
              organization_id: job_record.job.organization_id,
              job_record_id: job_record.id,
              channel: "sms",
              user_id: officer.id,
              notification_type: "rpa_upload_failure",
              status: "queued", 
              sent_at: nil,
              error_msg: nil
            )
            notifications << sms_notification
          end
        end
        
        notifications
      end

      def send_email_notifications!(notifications, error_context)
        email_notifications = notifications.select { |n| n.channel == "email" }
        
        email_notifications.each do |notification|
          begin
            # In production, this would use ActionMailer or similar
            send_detailed_email!(notification, error_context)
            
            notification.update!(
              status: "sent",
              sent_at: Time.current
            )
            
            Rails.logger.info "Sent RPA failure email notification to user #{notification.user_id}"
            
          rescue StandardError => e
            notification.update!(
              status: "failed",
              error_msg: "Email send failed: #{e.message}"
            )
            
            Rails.logger.error "Failed to send email notification: #{e.message}"
          end
        end
      end

      def send_detailed_email!(notification, error_context)
        user = notification.user
        loan_info = error_context[:loan_application]
        
        Rails.logger.info "Sending detailed RPA failure email to #{user.email} (#{user.name})"
        Rails.logger.info "Loan: #{loan_info[:los_external_id]} - #{loan_info[:applicant_id]}"
        
        # Send email using ActionMailer
        RpaFailureMailer.escalation_notification(notification, error_context).deliver_now
        
        Rails.logger.info "RPA failure escalation email sent successfully"
      end

      def build_email_body(error_context)
        loan = error_context[:loan_application]
        retry_info = error_context[:retry_summary]
        final_error = error_context[:final_error]
        escalation = error_context[:escalation_info]
        
        body = <<~EMAIL
          URGENT: Manual Intervention Required - RPA Upload Failed
          
          A pay stub document upload has failed all automated retry attempts and requires immediate manual intervention.
          
          LOAN DETAILS:
          - Applicant ID: #{loan[:applicant_id]}
          - LOS External ID: #{loan[:los_external_id]}
          - Loan Status: #{loan[:status]}
          - Approved At: #{loan[:approved_at]}
          
          FAILURE SUMMARY:
          - Total Attempts: #{retry_info[:total_attempts]} of #{retry_info[:max_attempts_allowed]}
          - First Failure: #{retry_info[:first_failure_at]}
          - Final Failure: #{retry_info[:final_failure_at]}
          - Time Span: #{retry_info[:time_span_hours]} hours
          
          FINAL ERROR:
          - Error Code: #{final_error[:code]}
          - Error Message: #{final_error[:message]}
          - Error Type: #{final_error[:error_class]}
          - Is Retryable: #{final_error[:is_retryable]}
          
          FAILURE PATTERN ANALYSIS:
          #{format_failure_analysis(error_context[:failure_analysis])}
          
          UPLOAD ATTEMPT HISTORY:
          #{format_upload_attempts(error_context[:upload_attempts])}
          
          SUGGESTED ACTIONS:
          #{escalation[:suggested_actions].join("\n")}
          
          Please investigate and take manual action as needed. The system will not automatically retry this upload.
          
          Job Record ID: #{error_context[:job_record_id]}
          Escalated At: #{escalation[:escalated_at]}
          
          To view detailed status: [System URL]/rpa_uploads/job_record/#{error_context[:job_record_id]}
        EMAIL
        
        body
      end

      def send_sms_notifications!(notifications, error_context)
        sms_notifications = notifications.select { |n| n.channel == "sms" }
        
        sms_notifications.each do |notification|
          begin
            send_sms!(notification, error_context)
            
            notification.update!(
              status: "sent",
              sent_at: Time.current
            )
            
          rescue StandardError => e
            notification.update!(
              status: "failed", 
              error_msg: "SMS send failed: #{e.message}"
            )
          end
        end
      end

      def send_sms!(notification, error_context)
        loan = error_context[:loan_application]
        
        message = "URGENT: RPA upload failed for loan #{loan[:los_external_id]} (#{loan[:applicant_id]}). " \
                 "#{error_context[:retry_summary][:total_attempts]} attempts failed. Manual intervention required."
        
        Rails.logger.info "SMS notification: #{message}"
        # In production: integrate with Twilio, AWS SNS, etc.
      end

      def send_team_notifications!(job_record, error_context)
        # Send to Slack, Microsoft Teams, or similar if configured
        organization = job_record.job.organization
        
        # This would integrate with organization's team communication tools
        Rails.logger.info "Team notification: RPA upload failure for loan #{error_context[:loan_application][:los_external_id]}"
      end

      def should_send_sms?(job_record)
        # Send SMS for high-value loans, urgent cases, or based on organization preferences
        loan_application = job_record.loan_application
        
        # Example criteria:
        # - Loan approved recently (within 24 hours)
        # - High retry count suggests persistent issue
        # - Organization has SMS notifications enabled
        
        loan_application.approved_at && 
          loan_application.approved_at > 24.hours.ago ||
          job_record.retry_count >= 2
      end

      def log_escalation_event!(job_record, error_context, notifications)
        Event.create!(
          organization_id: job_record.job.organization_id,
          user_id: job_record.job.user_id,
          job_id: job_record.job_id,
          job_record_id: job_record.id,
          event_type: "rpa_upload_escalated",
          phase: "escalation",
          severity: "error",
          message: "RPA upload escalated to #{notifications.size} lending officers after #{job_record.retry_count} failed attempts. Final error: #{error_context[:final_error][:message]}",
          ts: Time.current,
          trace_id: SecureRandom.hex(10)
        )
      end

      def mark_as_escalated!(job_record, error_context)
        job_record.update!(
          state: "escalated",
          last_error_code: "escalated_to_human",
          last_error_msg: "Escalated to human intervention after #{job_record.retry_count} failed attempts"
        )
      end

      def get_max_retries(organization)
        RetryPolicy.find_by(name: "default")&.max_attempts || 3
      end

      def calculate_failure_time_span(rpa_uploads)
        first_failure = rpa_uploads.where(status: "failed").first
        last_failure = rpa_uploads.last
        
        return 0 unless first_failure&.created_at && last_failure&.ended_at
        
        ((last_failure.ended_at - first_failure.created_at) / 1.hour).round(1)
      end

      def analyze_failure_patterns(rpa_uploads)
        failed_uploads = rpa_uploads.where(status: "failed")
        
        error_codes = failed_uploads.pluck(:error_code).compact
        error_frequency = error_codes.tally
        
        most_common_error = error_frequency.max_by { |_, count| count }&.first
        
        {
          total_failures: failed_uploads.count,
          unique_error_codes: error_codes.uniq,
          error_frequency: error_frequency,
          most_common_error: most_common_error,
          pattern_analysis: detect_patterns(failed_uploads)
        }
      end

      def detect_patterns(failed_uploads)
        patterns = []
        
        # Check for timeout patterns
        timeout_count = failed_uploads.where(error_code: ["los_timeout_error", "timeout"]).count
        if timeout_count >= 2
          patterns << "Repeated timeout errors suggest LOS system performance issues"
        end
        
        # Check for authentication patterns
        auth_count = failed_uploads.where(error_code: "los_authentication_error").count
        if auth_count >= 1
          patterns << "Authentication errors suggest credential or session management issues"
        end
        
        # Check for system error patterns
        system_count = failed_uploads.where(error_code: "los_system_error").count
        if system_count >= 2
          patterns << "System errors suggest LOS application issues"
        end
        
        patterns.empty? ? ["No clear error pattern detected"] : patterns
      end

      def generate_suggested_actions(job_record, rpa_uploads)
        actions = []
        
        # Basic actions
        actions << "1. Review loan application #{job_record.loan_application.los_external_id} in LOS system"
        actions << "2. Verify document is available and properly formatted"
        actions << "3. Check LOS system status and connectivity"
        
        # Specific actions based on error patterns
        latest_error = rpa_uploads.last&.error_code
        
        case latest_error
        when "los_timeout_error", "timeout"
          actions << "4. Check LOS system performance and network connectivity"
          actions << "5. Consider uploading during off-peak hours"
        when "los_authentication_error"
          actions << "4. Verify RPA credentials and session management"
          actions << "5. Check if LOS authentication requirements have changed"
        when "los_system_error"
          actions << "4. Check LOS system status and error logs"
          actions << "5. Contact LOS support if system issues persist"
        when "document_format_error"
          actions << "4. Verify document format and content"
          actions << "5. Request new document from applicant if corrupted"
        else
          actions << "4. Review detailed error logs for specific failure cause"
          actions << "5. Consider manual upload through LOS interface"
        end
        
        actions << "6. Contact IT support if technical issues persist"
        actions << "7. Update applicant on status and next steps"
        
        actions
      end

      def format_failure_analysis(analysis)
        lines = []
        lines << "- Total Failures: #{analysis[:total_failures]}"
        lines << "- Unique Error Types: #{analysis[:unique_error_codes].join(', ')}"
        lines << "- Most Common Error: #{analysis[:most_common_error]}"
        lines << "- Pattern Analysis:"
        analysis[:pattern_analysis].each { |pattern| lines << "  * #{pattern}" }
        lines.join("\n")
      end

      def format_upload_attempts(attempts)
        lines = []
        attempts.each do |attempt|
          duration = attempt[:duration_seconds] ? "#{attempt[:duration_seconds]}s" : "N/A"
          lines << "Attempt #{attempt[:attempt]}: #{attempt[:status]} (#{duration}) - #{attempt[:error_message]}"
        end
        lines.join("\n")
      end
    end
  end
end

class RpaFailureMailer < ApplicationMailer
  default from: 'noreply@pscagent.com'

  # Send escalation notification to lending officer
  def escalation_notification(notification, error_context)
    @notification = notification
    @user = notification.user
    @organization = notification.organization
    @error_context = error_context
    @job_record_id = notification.job_record_id
    @loan_info = @error_context[:loan_application]
    @retry_info = @error_context[:retry_summary]
    @final_error = @error_context[:final_error]
    @escalation_info = @error_context[:escalation_info]
    
    # Prepare display-friendly data
    @formatted_failure_analysis = format_failure_analysis(@error_context[:failure_analysis])
    @formatted_upload_attempts = format_upload_attempts(@error_context[:upload_attempts])
    @formatted_suggested_actions = @escalation_info[:suggested_actions].join("\n")
    
    # Set email properties
    @subject = "URGENT: RPA Upload Failed - Manual Intervention Required (Loan #{@loan_info[:los_external_id]})"
    @priority = 'high'
    
    mail(
      to: @user.email,
      subject: @subject,
      priority: @priority,
      importance: 'high',
      'X-MSMail-Priority' => 'High'
    )
  end

  # Send digest of multiple failures (optional - for batch notifications)
  def failure_digest(user, failed_uploads_summary, time_period)
    @user = user
    @organization = user.organization
    @failed_uploads_summary = failed_uploads_summary
    @time_period = time_period
    @total_failures = failed_uploads_summary.size
    
    subject = "RPA Upload Failures Digest - #{@total_failures} failures in #{time_period}"
    
    mail(
      to: user.email,
      subject: subject
    )
  end

  # Send resolution notification when manual intervention completes
  def resolution_notification(job_record, resolved_by_user, resolution_notes)
    @job_record = job_record
    @loan_application = job_record.loan_application
    @organization = job_record.job.organization
    @resolved_by = resolved_by_user
    @resolution_notes = resolution_notes
    
    # Find all users who were originally notified
    original_notifications = Notification.where(
      job_record: job_record,
      notification_type: "rpa_upload_failure",
      status: "sent"
    ).includes(:user)
    
    recipient_emails = original_notifications.map(&:user).map(&:email).uniq
    
    mail(
      to: recipient_emails,
      subject: "RESOLVED: RPA Upload Issue - Loan #{@loan_application.los_external_id}"
    )
  end

  private

  def format_failure_analysis(analysis)
    lines = []
    lines << "Total Failures: #{analysis[:total_failures]}"
    lines << "Unique Error Types: #{analysis[:unique_error_codes].join(', ')}" unless analysis[:unique_error_codes].empty?
    lines << "Most Common Error: #{analysis[:most_common_error]}" if analysis[:most_common_error]
    lines << ""
    lines << "Pattern Analysis:"
    analysis[:pattern_analysis].each { |pattern| lines << "• #{pattern}" }
    lines.join("\n")
  end

  def format_upload_attempts(attempts)
    return "No upload attempts recorded" if attempts.empty?
    
    lines = []
    attempts.each do |attempt|
      duration = attempt[:duration_seconds] ? "#{attempt[:duration_seconds]}s" : "N/A"
      status_icon = attempt[:status] == "succeeded" ? "✓" : "✗"
      lines << "#{status_icon} Attempt #{attempt[:attempt]}: #{attempt[:status]} (#{duration})"
      if attempt[:error_message].present?
        lines << "   Error: #{attempt[:error_message]}"
      end
    end
    lines.join("\n")
  end
end

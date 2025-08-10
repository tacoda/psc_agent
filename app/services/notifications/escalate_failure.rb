module Notifications
  class EscalateFailure
    def self.call!(job_record:)
      Notification.create!(
        organization_id: job_record.job.organization_id,
        job_record_id: job_record.id,
        channel: "email",
        user_id: job_record.job.user_id,
        notification_type: "failure",
        status: "queued",
        sent_at: Time.current,
        error_msg: "Automated retries exhausted"
      )
    end
  end
end

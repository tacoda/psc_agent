module PayStub
  class ConcludeJob < BaseJob

    def perform(job_record_id)
      jr = job_record or raise "JobRecord not found"
      # Mark done + notify success
      jr.update!(state: "completed")
      Notification.create!(
        organization_id: jr.job.organization_id,
        job_record_id: jr.id,
        channel: "email",
        user_id: jr.job.user_id,
        notification_type: "success",
        status: "queued",
        sent_at: Time.current
      )
    end
  end
end

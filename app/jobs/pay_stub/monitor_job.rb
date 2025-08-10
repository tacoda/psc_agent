# Explicitly require the service to ensure it's available in all contexts
require Rails.root.join('app', 'services', 'notifications', 'escalate_failure')

module PayStub
  class MonitorJob < BaseJob

    def perform(job_record_id)
      jr = job_record or raise "JobRecord not found"
      # Emit metrics, verify downstream LOS state if possible, detect stalls
      # If stalled or failed thrice, escalate
      if jr.state == "failed" || jr.retry_count >= 3
        # Explicitly reference the constant to trigger autoloading
        ::Notifications::EscalateFailure.call!(job_record: jr)
        jr.update!(state: "escalated")
      end
    end
  end
end

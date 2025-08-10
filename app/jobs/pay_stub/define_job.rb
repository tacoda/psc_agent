module PayStub
  class DefineJob < BaseJob

    # perform(job_record_id)
    def perform(job_record_id)
      jr = job_record or raise "JobRecord not found"
      with_lock!(jr) do
        # Evaluate routing rules / readiness
        jr.update!(state: "collecting", next_attempt_at: Time.current)
      end
    end
  end
end

module PayStub
  class ModifyJob < BaseJob

    def perform(job_record_id)
      jr = job_record or raise "JobRecord not found"
      # Apply business-side corrections (e.g., fix metadata/routing after canary)
      jr.touch(:updated_at)
    end
  end
end

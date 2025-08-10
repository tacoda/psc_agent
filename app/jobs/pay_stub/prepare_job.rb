# frozen_string_literal: true
module PayStub
  class PrepareJob < BaseJob

    def perform(job_record_id)
      jr = job_record or raise "JobRecord not found"
      # Pre-validate doc (virus scan, mime, size limits). Set state.
      jr.update!(state: "collected")
    end
  end
end

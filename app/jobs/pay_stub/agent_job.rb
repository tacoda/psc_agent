module PayStub
  class AgentJob < BaseJob
    queue_as :agent

    # perform(job_record_id)
    def perform(job_record_id)
      jr = job_record or raise "JobRecord not found"

      # Phase 1: define → locate → prepare
      DefineJob.perform_now(jr.id)
      LocateJob.perform_now(jr.id)
      PrepareJob.perform_now(jr.id)

      # Phase 2: confirm → execute (RPA) → monitor (post-check)
      ConfirmJob.perform_now(jr.id)
      ExecuteJob.perform_now(jr.id)
      MonitorJob.perform_now(jr.id)

      # Phase 3: modify (optional corrections) → conclude
      ModifyJob.perform_now(jr.id)
      ConcludeJob.perform_now(jr.id)
    end
  end
end

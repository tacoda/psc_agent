module PayStub
  class ExecuteJob < BaseJob

    def perform(job_record_id)
      jr = job_record or raise "JobRecord not found"
      doc = Document.find_by!(loan_application_id: jr.loan_application_id, document_type: "PAY_STUB")

      run = AgentRun.create!(
        job_record: jr, phase: "upload", status: "in_progress",
        started_at: Time.current, worker_id: "rpa-#{SecureRandom.hex(3)}",
        idempotency_key: SecureRandom.uuid
      )

      # Invoke RPA (out-of-process). Placeholder:
      success = simulate_rpa_upload!(jr: jr, doc: doc)

      run.update!(status: (success ? "succeeded" : "failed"), ended_at: Time.current)
      if success
        doc.update!(status: "verified")
        jr.update!(state: "uploaded")
      else
        jr.increment!(:retry_count)
        raise "RPA upload failed"
      end
    end

    private

    def simulate_rpa_upload!(jr:, doc:)
      RpaUpload.create!(
        job_record: jr, document: doc, los_session_id: SecureRandom.hex(6),
        status: "succeeded", attempt: jr.retry_count + 1,
        started_at: Time.current - 30.seconds, ended_at: Time.current
      )
      true
    end
  end
end

class CreateAgentRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :agent_runs do |t|
      t.references :job_record, null: false, foreign_key: true
      t.string :phase
      t.string :status
      t.datetime :started_at
      t.datetime :ended_at
      t.string :worker_id
      t.string :idempotency_key

      t.timestamps
    end
    add_index :agent_runs, :idempotency_key
  end
end

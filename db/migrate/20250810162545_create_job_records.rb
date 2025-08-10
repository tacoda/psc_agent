class CreateJobRecords < ActiveRecord::Migration[8.0]
  def change
    create_table :job_records do |t|
      t.references :job, null: false, foreign_key: true
      t.references :loan_application, null: false, foreign_key: true
      t.string :state
      t.integer :retry_count
      t.datetime :next_attempt_at
      t.string :last_error_code
      t.text :last_error_msg
      t.bigint :solid_queue_job_id

      t.timestamps
    end
    add_index :job_records, :solid_queue_job_id
  end
end

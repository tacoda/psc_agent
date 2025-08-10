class CreateRpaUploads < ActiveRecord::Migration[8.0]
  def change
    create_table :rpa_uploads do |t|
      t.references :job_record, null: false, foreign_key: true
      t.references :document, null: false, foreign_key: true
      t.string :los_session_id
      t.string :status
      t.integer :attempt
      t.datetime :started_at
      t.datetime :ended_at
      t.string :error_code
      t.text :error_msg

      t.timestamps
    end
  end
end

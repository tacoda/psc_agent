class CreateNotifications < ActiveRecord::Migration[8.0]
  def change
    create_table :notifications do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :job_record, null: false, foreign_key: true
      t.string :channel
      t.references :user, null: false, foreign_key: true
      t.string :notification_type
      t.string :status
      t.datetime :sent_at
      t.string :error_msg

      t.timestamps
    end
  end
end

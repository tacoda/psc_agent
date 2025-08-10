class CreateEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :events do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :job, null: false, foreign_key: true
      t.references :job_record, null: false, foreign_key: true
      t.string :type
      t.string :phase
      t.string :severity
      t.text :message
      t.datetime :ts
      t.string :trace_id

      t.timestamps
    end
    add_index :events, :trace_id
  end
end

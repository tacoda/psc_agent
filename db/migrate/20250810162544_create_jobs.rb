class CreateJobs < ActiveRecord::Migration[8.0]
  def change
    create_table :jobs do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :agent_type
      t.string :trigger_source
      t.references :user, null: false, foreign_key: true
      t.string :status
      t.integer :total_records

      t.timestamps
    end
  end
end

class AddTimestampsToJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :jobs, :started_at, :datetime
    add_column :jobs, :completed_at, :datetime
  end
end

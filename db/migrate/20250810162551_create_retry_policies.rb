class CreateRetryPolicies < ActiveRecord::Migration[8.0]
  def change
    create_table :retry_policies do |t|
      t.string :name
      t.integer :max_attempts
      t.integer :base_backoff_sec
      t.integer :jitter_pct

      t.timestamps
    end
  end
end

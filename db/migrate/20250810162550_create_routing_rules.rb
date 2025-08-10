class CreateRoutingRules < ActiveRecord::Migration[8.0]
  def change
    create_table :routing_rules do |t|
      t.references :organization, null: false, foreign_key: true
      t.boolean :enabled
      t.jsonb :criteria_json
      t.string :checksum
      t.boolean :canary

      t.timestamps
    end
  end
end

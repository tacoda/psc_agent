class CreateDocuments < ActiveRecord::Migration[8.0]
  def change
    create_table :documents do |t|
      t.references :loan_application, null: false, foreign_key: true
      t.string :type
      t.string :status
      t.string :sha256
      t.bigint :size_bytes
      t.string :storage_url
      t.string :kms_key_id

      t.timestamps
    end
    add_index :documents, :sha256
  end
end

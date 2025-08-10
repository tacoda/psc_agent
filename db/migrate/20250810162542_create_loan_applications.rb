class CreateLoanApplications < ActiveRecord::Migration[8.0]
  def change
    create_table :loan_applications do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :applicant_id
      t.string :los_external_id
      t.string :status
      t.boolean :income_doc_required
      t.datetime :approved_at

      t.timestamps
    end
  end
end

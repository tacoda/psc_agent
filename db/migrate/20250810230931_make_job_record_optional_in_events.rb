class MakeJobRecordOptionalInEvents < ActiveRecord::Migration[8.0]
  def change
    change_column_null :events, :job_record_id, true
  end
end

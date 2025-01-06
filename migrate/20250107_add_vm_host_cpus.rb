# frozen_string_literal: true

Sequel.migration do
  change do
    create_table :vm_host_cpu do
      column :id, :uuid, primary_key: true
      foreign_key :vm_host_id, :vm_host, type: :uuid, null: false
      Integer :cpu_number, null: false
      Boolean :available, null: false

      unique [:vm_host_id, :cpu_number]
    end
  end
end

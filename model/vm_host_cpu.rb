require_relative "../model"

class VmHostCpu < Sequel::Model
  many_to_one :vm_host
  include ResourceMethods
end

# Table: vm_host_cpu
# Columns:
#  id         | uuid    | PRIMARY KEY
#  vm_host_id | uuid    | NOT NULL
#  cpu_number | integer | NOT NULL
#  available  | boolean | NOT NULL
# Indexes:
#  vm_host_cpu_pkey                      | PRIMARY KEY btree (id)
#  vm_host_cpu_vm_host_id_cpu_number_key | UNIQUE btree (vm_host_id, cpu_number)
# Foreign key constraints:
#  vm_host_cpu_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)

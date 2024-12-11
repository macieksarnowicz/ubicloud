# frozen_string_literal: true

require_relative "../model"

class ObjectTag < Sequel::Model
  include ResourceMethods
  include AccessControlModelTag
  dataset_module Authorization::Dataset

  def self.valid_member?(project_id, object)
    case object
    when ObjectTag, ObjectMetatag, SubjectTag, ActionTag, InferenceEndpoint
      object.project_id == project_id
    when Vm, PrivateSubnet, PostgresResource, Firewall, LoadBalancer
      !AccessTag.where(project_id:, hyper_tag_id: object.id).empty?
    when Project
      object.id == project_id
    when ApiKey
      object.owner_table == "project" && object.owner_id == project_id
    end
  end

  def metatag
    ObjectMetatag.new(self)
  end

  def metatag_ubid
    ObjectMetatag.to_meta(ubid)
  end

  def metatag_uuid
    UBID.to_uuid(metatag_ubid)
  end

  def before_destroy
    applied_dataset.where(object_id: metatag_uuid).delete
    AccessControlEntry.where(object_id: metatag_uuid).destroy
    super
  end
end

# Table: object_tag
# Columns:
#  id         | uuid | PRIMARY KEY
#  project_id | uuid | NOT NULL
#  name       | text | NOT NULL
# Indexes:
#  object_tag_pkey                  | PRIMARY KEY btree (id)
#  object_tag_project_id_name_index | UNIQUE btree (project_id, name)
# Foreign key constraints:
#  object_tag_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  applied_object_tag | applied_object_tag_tag_id_fkey | (tag_id) REFERENCES object_tag(id)

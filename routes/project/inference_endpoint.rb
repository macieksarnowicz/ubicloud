# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-endpoint") do |r|
    r.get web? do
      @inference_endpoints = Serializers::InferenceEndpoint.serialize(inference_endpoint_ds.eager(:location).all)
      @remaining_free_quota = FreeQuota.remaining_free_quota("inference-tokens", @project.id)
      @free_quota_unit = "inference tokens"
      @has_valid_payment_method = @project.has_valid_payment_method?
      view "inference/endpoint/index"
    end
  end
end

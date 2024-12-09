# frozen_string_literal: true

class Clover
  def private_subnet_list
    dataset = @project.private_subnets_dataset.authorized(current_account.id, "PrivateSubnet:view")

    if api?
      dataset = dataset.where(location: @location) if @location
      result = dataset.eager(nics: [:private_subnet]).paginated_result(
        start_after: request.params["start_after"],
        page_size: request.params["page_size"],
        order_column: request.params["order_column"]
      )

      {
        items: Serializers::PrivateSubnet.serialize(result[:records]),
        count: result[:count]
      }
    else
      @pss = Serializers::PrivateSubnet.serialize(dataset.all, {include_path: true})
      view "networking/private_subnet/index"
    end
  end

  def private_subnet_post(name)
    Authorization.authorize(current_account.id, "PrivateSubnet:create", @project.id)

    params = json_params
    unless params.empty?
      required_parameters = []
      required_parameters << "name" << "location" if web?
      request_body_params = Validation.validate_request_body(params, required_parameters, ["firewall_id"])
      firewall_id = if request_body_params["firewall_id"]
        fw = Firewall.from_ubid(request_body_params["firewall_id"])
        unless fw && fw.location == @location
          fail Validation::ValidationFailed.new(firewall_id: "Firewall with id \"#{request_body_params["firewall_id"]}\" and location \"#{@location}\" is not found")
        end
        Authorization.authorize(current_account.id, "Firewall:view", fw.id)
        fw.id
      end
    end

    st = Prog::Vnet::SubnetNexus.assemble(
      @project.id,
      name:,
      location: @location,
      firewall_id:
    )

    if api?
      Serializers::PrivateSubnet.serialize(st.subject)
    else
      flash["notice"] = "'#{name}' will be ready in a few seconds"
      request.redirect "#{@project.path}#{PrivateSubnet[st.id].path}"
    end
  end
end

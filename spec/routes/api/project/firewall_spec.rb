# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "firewall" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:firewall) { Firewall.create_with_id(name: "default-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: project.id) }

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/firewall"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not create" do
      post "/project/#{project.ubid}/firewall"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    it "success get all firewalls" do
      Firewall.create_with_id(name: "#{firewall.name}-2", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)

      get "/project/#{project.ubid}/firewall"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end
  end
end

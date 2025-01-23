# frozen_string_literal: true

class UbiCli
  def self.process(argv, env)
    UbiRodish.process(argv, context: new(env))
  rescue Rodish::CommandExit => e
    [e.failure? ? 400 : 200, {"content-type" => "text/plain"}, [e.message]]
  end

  def initialize(env)
    @env = env
  end

  def project_ubid
    @project_ubid ||= @env["clover.project_ubid"]
  end

  # Temporary nocov until cli command supported that uses post
  # :nocov:
  def post(path, params = {}, &block)
    env = _req_env("POST", path)
    env["rack.input"] = StringIO.new(params.to_json.force_encoding(Encoding::BINARY))
    _req(env, &block)
  end
  # :nocov:

  def get(path, &block)
    env = _req_env("GET", path)
    env["rack.input"] = StringIO.new("".b)
    _req(env, &block)
  end

  def _req_env(method, path)
    @env.merge(
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "rack.request.form_input" => nil,
      "rack.request.form_hash" => nil
    )
  end

  def project_path(rest)
    "/project/#{project_ubid}/#{rest}"
  end

  def format_rows(keys, rows, headers: false)
    results = []
    tab = false

    if headers
      keys.each do |key|
        if tab
          results << "\t"
        else
          tab = true
        end
        results << key.to_s
      end
      results << "\n"
    end

    rows.each do |row|
      tab = false
      keys.each do |key|
        if tab
          results << "\t"
        else
          tab = true
        end
        results << row[key].to_s
      end
      results << "\n"
    end

    results
  end

  def ipv6_request?
    @env["puma.socket"]&.local_address&.ipv6?
  end

  def _req(env)
    res = Clover.call(env)

    case res[0]
    when 200
      # Temporary nocov until at least one action pushed into routes
      # :nocov:
      if res[1]["content-type"] == "application/json"
        # :nocov:
        body = +""
        res[2].each { body << _1 }
        res[2] = yield(JSON.parse(body), res)
        res[1]["content-length"] = res[2].sum(&:bytesize).to_s
      end
    # Temporary nocov until cli command that deletes
    # :nocov:
    when 204
      # :nocov:
      # nothing, body should be empty
    else
      body = +""
      res[2].each { body << _1 }
      error_message = "Error: unexpected response status: #{res[0]}"
      # Temporary nocov until at least one action pushed into routes
      # :nocov:
      if res[1]["content-type"] == "application/json" && (error = JSON.parse(body).dig("error", "message"))
        # :nocov:
        error_message << "\nDetails: #{error}"
      end
      res[2] = [error_message]
      res[1]["content-length"] = res[2][0].bytesize.to_s
    end

    res[1]["content-type"] = "text/plain"
    res
  end
end

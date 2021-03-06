require "heroku/client"
require "json"
require "shellwords"
require "sinatra"
require "tmpdir"

class Heroku::Client
  def releases_new(app_name)
    json_decode(get("/apps/#{app_name}/releases/new").to_s)
  end

  def releases_create(app_name, payload)
    json_decode(post("/apps/#{app_name}/releases", json_encode(payload)))
  end

  def release(app_name, slug, description, head, options={})
    release = releases_new(app_name)
    RestClient.put(release["slug_put_url"], File.open(slug, "rb"), :content_type => nil)
    user = json_decode(get("/account").to_s)["email"]
    payload = release.merge({
      "slug_version" => 2,
      "run_deploy_hooks" => true,
      "user" => user,
      "release_descr" => description,
      "head" => head
    }) { |k, v1, v2| v1 || v2 }.merge(options)
    releases_create(app_name, payload)
  end

  def release_slug(app_name)
    json_decode(get("/apps/#{app_name}/release_slug").to_s)
  end

  def user_info
     json_decode(get("/user", { :accept => 'application/json' }).to_s)
  end

  # todo: temp...remove
  def releases(app)
    json_decode(get("/apps/#{app}/releases", { :accept => 'application/json' }).to_s)
  end
end

helpers do
  def api(key, cloud="standard")
    client = Heroku::Client.new("", key)
    client.host = cloud
    client
  end

  def auth!
    response["WWW-Authenticate"] = %(Basic realm="Restricted Area")
    throw(:halt, [401, "Unauthorized"])
  end

  def creds
    auth = Rack::Auth::Basic::Request.new(request.env)
    auth.provided? && auth.basic? ? auth.credentials : auth!
  end

  def error(message)
    halt 422, { "error" => message }.to_json
  end

  def release_from_url(api_key, cloud, app, build_url, description, head, processes = nil)
    release = Dir.mktmpdir do |dir|
      escaped_build_url = Shellwords.escape(build_url)

      if build_url =~ /\.tgz$/
        %x{ mkdir -p #{dir}/tarball }
        %x{ cd #{dir}/tarball && curl #{escaped_build_url} -s -o- | tar xzf - }
        %x{ mksquashfs #{dir}/tarball #{dir}/squash -all-root }
        %x{ cp #{dir}/squash #{dir}/build }
      else
        %x{ curl #{escaped_build_url} -o #{dir}/build 2>&1 }
      end

      %x{ unsquashfs -d #{dir}/extract #{dir}/build Procfile }

      if processes
        procfile = processes
      else
        if File.exists?("#{dir}/extract/Procfile")
          procfile = File.read("#{dir}/extract/Procfile").split("\n").inject({}) do |ax, line|
            ax[$1] = $2 if line =~ /^([A-Za-z0-9_]+):\s*(.+)$/
            ax
          end
        end
      end

      release_options = {
          "process_types" => procfile
      }

      release = api(api_key, cloud).release(app, "#{dir}/build", description, head, release_options)
      release["release"]
    end

    content_type "application/json"
    JSON.dump({"release" => release})
  end
end

post "/apps/:app/release" do
  api_key = creds[1]

  halt(403, "must specify cloud") unless params[:cloud]
  halt(403, "must specify build_url") unless params[:build_url]
  halt(403, "must specify description") unless params[:description]

  head = Digest::SHA1.hexdigest(Time.now.to_f.to_s)
  release_from_url(api_key, params[:cloud], params[:app], params[:build_url], params[:description], head, params[:processes])
end

post "/apps/:source_app/copy/:target_app" do
  api_key = creds[1]

  halt(403, "must specify cloud") unless params[:cloud]
  halt(403, "must specify source_app") unless params[:source_app]
  halt(403, "must specify target_app") unless params[:target_app]

  api = api(api_key, params[:cloud])

  # metrics logging
  metrics = {
    'action' => 'copy',
    'user_agent' => request.user_agent,
    'user' => api.user_info['email'],
    'command' => params[:command],
    'source_app' => params[:source_app],
    'target_app' => params[:target_app],
    'result' => nil
  }

  begin
    begin
      source_slug = api.release_slug(params[:source_app])
    rescue RestClient::UnprocessableEntity
      halt(403, "no access to releases_slug")
    end

    descVerb = params[:command] == "pipeline:promote" ? "Promote" : "Copy"
    source_release =  api.releases(params[:source_app]).last
    head = source_release["commit"]
    halt(404, "Code release not found for #{params[:source_app]}") if head.nil?
    description = "#{descVerb} #{params[:source_app]} #{source_slug["name"]} #{head}"

    begin
      release = release_from_url(api_key, params[:cloud], params[:target_app], source_slug["slug_url"], description, head)
      metrics['result'] = 'success'
      release
    rescue RestClient::UnprocessableEntity
      halt(403, "no access to new-releases")
    end
  rescue => e
    metrics['result'] = e.message
    throw e
  ensure
    puts "metrics=#{Heroku::OkJson.encode metrics}"
  end
end

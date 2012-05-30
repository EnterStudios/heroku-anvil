require "cgi"
require "digest/sha2"
require "heroku/command/base"
require "net/https"
require "pathname"
require "tmpdir"

module Heroku::Releaser

  def release_slug(slug_url, app)
    Dir.mktmpdir do |dir|
      action("Downloading slug") do
        File.open("#{dir}/slug.img", "wb") do |file|
          file.print RestClient.get(slug_url).body
        end
      end
      release = heroku.releases_new(app)
      action("Uploading slug for release") do
        res = RestClient.put(release["slug_put_url"], File.open("#{dir}/slug.img", "rb"), :content_type => nil)
      end
      action("Releasing to #{app}") do
        payload = release.merge({
          "slug_version" => 2,
          "run_deploy_hooks" => true,
          "user" => heroku.user,
          "release_descr" => "Anvil deploy",
          "head" => Digest::SHA1.hexdigest(Time.now.to_f.to_s),
          "process_types" => parse_procfile("Procfile")
        }) { |k, v1, v2| v1 || v2 }
        release = heroku.releases_create(app, payload)
        @status = release["release"]
      end
    end
  end

  def parse_procfile(filename)
    return {} unless File.exists?(filename)
    File.read(filename).split("\n").inject({}) do |ax, line|
      if line =~ /^([A-Za-z0-9_]+):\s*(.+)$/
        ax[$1] = $2
      end
      ax
    end
  end

end

# deploy code
#
class Heroku::Command::Push < Heroku::Command::Base

  include Heroku::Releaser

  PUSH_THREAD_COUNT = 40

  # push [DIR]
  #
  # deploy code
  #
  # -b, --buildpack URL  # use a custom buildpack
  # -e, --runtime-env    # use runtime environment during build
  # -r, --release        # release the slug to an app
  #
  def index
    dir = shift_argument || "."
    manifest = action("Generating application manifest") do
      directory_manifest(dir)
    end
    missing_hashes = action("Computing diff for upload") do
      missing = json_decode(anvil["/manifest/diff"].post(:manifest => json_encode(manifest)).to_s)
      @status = "#{missing.length} files needed"
      missing
    end
    @status = nil
    action("Uploading new files") do
      upload_missing_files(manifest, missing_hashes)
    end

    uri = URI.parse("#{anvil_host}/manifest/build")

    http = Net::HTTP.new(uri.host, uri.port)

    if uri.scheme == "https"
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    req = Net::HTTP::Post.new uri.request_uri

    env = options[:runtime_env] ? heroku.config_vars(app) : {}

    req.set_form_data({
      "env"       => env,
      "manifest"  => json_encode(manifest),
      "buildpack" => options[:buildpack]
    })

    slug_url = nil

    http.request(req) do |res|
      slug_url = res["x-slug-url"]
      res.read_body do |chunk|
        print chunk
      end
    end

    if options[:release]
      release_slug slug_url, app
    end
  end


private

  def anvil_host
    ENV["ANVIL_HOST"] || "http://anvil.herokuapp.com"
  end

  def anvil
    RestClient::Resource.new(anvil_host, auth.user, auth.password)
  end

  def auth
    Heroku::Auth
  end

  def directory_manifest(dir)
    root = Pathname.new(dir)

    Dir[File.join(dir, "**", "*")].inject({}) do |hash, file|
      hash[Pathname.new(file).relative_path_from(root).to_s] = file_manifest(file) unless File.directory?(file)
      hash
    end
  end

  def file_manifest(file)
    stat = File.stat(file)

    {
      "ctime" => stat.ctime.to_i,
      "mtime" => stat.mtime.to_i,
      "mode"  => "%o" % stat.mode,
      "hash"  => Digest::SHA2.hexdigest(File.open(file, "rb").read)
    }
  end

  def manifest_names_by_hash(manifest)
    manifest.inject({}) do |ax, (name, file_manifest)|
      ax.update file_manifest["hash"] => name
    end
  end

  def parse_procfile(filename)
    return {} unless File.exists?(filename)
    File.read(filename).split("\n").inject({}) do |ax, line|
      if line =~ /^([A-Za-z0-9_]+):\s*(.+)$/
        ax[$1] = $2
      end
      ax
    end
  end

  def upload_file(hash, name)
    anvil["/file/#{hash}"].post :data => File.new(name, "rb")
  end

  def upload_missing_files(manifest, missing_hashes)
    names_by_hash = manifest_names_by_hash(manifest)
    bucket_missing_hashes = missing_hashes.inject({}) do |ax, hash|
      index = hash.hash % PUSH_THREAD_COUNT
      ax[index] ||= []
      ax[index]  << hash
      ax
    end
    threads = bucket_missing_hashes.values.map do |hashes|
      Thread.new do
        hashes.each do |hash|
          upload_file hash, names_by_hash[hash]
        end
      end
    end
    threads.each(&:join)
  end

end

# release code
#
class Heroku::Command::Release < Heroku::Command::Base

  include Heroku::Releaser

  # release SLUG_URL
  #
  # release a slug
  #
  def index
    error("Usage: heroku release SLUG_URL") unless slug_url = shift_argument
    release_slug(slug_url, app)
  end

end

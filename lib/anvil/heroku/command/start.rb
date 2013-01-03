require "anvil/helpers"
require "anvil/manifest"
require "distributor/client"
require "listen"
require "pathname"

# run your local code on heroku
#
class Heroku::Command::Start < Heroku::Command::Base

  include Anvil::Helpers

  PROTOCOL_COMMAND_HEADER = "\000\042\000"
  PROTOCOL_COMMAND_EXIT   = 1

  # start [DIR]
  #
  # start a development dyno on development app APP
  #
  # -b, --buildpack    # use a custom buildpack
  # -e, --runtime-env  # use the runtime env
  #
  def index
    dir = Pathname.new(File.expand_path(shift_argument || ".")).realpath.to_s
    app = options[:app] || error("Must specify a development app with -a")
    validate_arguments!

    user = api.post_login("", Heroku::Auth.password).body["email"]

    Anvil.append_agent "interface=start user=#{user} app=#{app}"

    slug_url = Anvil::Engine.build(dir, :buildpack => options[:buildpack])

    action("Preparing development dyno on #{app}") do
      heroku.release(app, "Initial development dyno sync", :slug_url => development_dyno_slug_url){
        print "."
        $stdout.flush
      }
    end

    build_env = {
      "ANVIL_HOST"    => ENV["ANVIL_HOST"] || "https://api.anvilworks.org",
      "BUILDPACK_URL" => prepare_buildpack(options[:buildpack]),
      "SLUG_URL"      => slug_url
    }

    develop_options = build_env.inject({}) do |ax, (key, val)|
      ax.update("ps_env[#{key}]" => val)
    end

    process = action("Starting development dyno") do
      status "http://localhost:9000"
      run_attached app, "bin/development-dyno", develop_options
    end

    client_to_dyno = pipe
    dyno_to_client = pipe

    client = Distributor::Client.new(dyno_to_client.first, client_to_dyno.last)

    client.on_hello do
      client.run("/app/vendor/bundle/ruby/1.9.1/bin/foreman start -c -p 5000 -m all=1,rake=0,console=0") do |ch|
        client.hookup ch, $stdin.dup, $stdout.dup
        client.on_close(ch) { shutdown(app, process["process"]) }
      end

      start_file_watcher   client, dir
      start_console_server client, dir
      start_http_tunnel    client, 5000, 9000
    end

    client.on_command do |command, data|
      case command
      when /file.*/
        # sync complete messages
      when "error"
        error data["message"]
      end
    end

    Thread.abort_on_exception = true

    rendezvous = Heroku::Client::Rendezvous.new(
      :rendezvous_url => process["rendezvous_url"],
      :connect_timeout => 120,
      :activity_timeout => nil,
      :input => client_to_dyno.first,
      :output => dyno_to_client.last
    )

    rendezvous.on_connect do
      Thread.new { client.start }
    end

    Signal.trap("INT") do
      shutdown(app, process["process"])
    end

    begin
      $stdin.sync = $stdout.sync = true
      set_buffer false
      rendezvous.start
    rescue Timeout::Error
      error "\nTimeout awaiting process"
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError
      error "\nError connecting to process"
    rescue Interrupt
    ensure
      set_buffer true
    end
  end

  # start:console
  #
  # get a console into your development dyno
  #
  def console
    connector = Distributor::Connector.new
    console   = TCPSocket.new("localhost", read_anvil_metadata(".", "console.port").to_i)

    set_buffer false

    connector.handle(console) do |io|
      $stdout.write io.readpartial(4096)
      $stdout.flush
    end

    connector.handle($stdin.dup) do |io|
      console.write io.readpartial(4096)
      console.flush
    end

    connector.on_close(console) do
      exit 0
    end

    connector.on_close($stdin.dup) do |io|
      exit 0
    end

    loop { connector.listen }
  rescue Errno::ECONNREFUSED
    error "Unable to connect to development dyno"
  ensure
    set_buffer true
  end

private

  def development_dyno_slug_url
    ENV["DEVELOPMENT_DYNO_SLUG_URL"] || "https://api.anvilworks.org/slugs/889a67b1-fc71-11e1-97c4-e57ab9695538.tgz"
  end

  def run_attached(app, command, options={})
    process_data = api.post_ps(app, command, { :attach => true }.merge(options)).body
    process_data
  end

  def upload_manifest(name, dir)
    manifest = Heroku::Manifest.new(dir)

    action("Synchronizing local files") do
      count = manifest.upload
    end

    manifest
  end

  def prepare_buildpack(buildpack_url)
    return "https://buildkit.herokuapp.com/buildkit/default.tgz" unless buildpack_url
    return buildpack_url unless File.exists?(buildpack_url) && File.directory?(buildpack_url)
    manifest = upload_manifest("buildpack", buildpack_url)
    manifest.save
  end

  def process_commands(chunk)
    if location = chunk.index(PROTOCOL_COMMAND_HEADER)
      buffer = StringIO.new(chunk[location..-1])
      header = buffer.read(3)
      case command = buffer.read(1).ord
      when PROTOCOL_COMMAND_EXIT then
        code = buffer.read(1).ord
        unless code.zero?
          puts "ERROR: Build exited with code: #{code}"
          exit code
        end
      else
        puts "unknown[#{command}]"
      end
      chunk = chunk[0..location-1]
    end
    chunk
  end

  def pipe
    IO.method(:pipe).arity.zero? ? IO.pipe : IO.pipe("BINARY")
  end

  def shutdown(app, process)
    # api.post_ps_stop app, :ps => process
    exit 0
  end

  def upload_file(dir, file, client)
    return if ignore_file?(File.join(dir, file))
    manifest = Anvil::Manifest.new
    full_filename = File.join(dir, file)
    manifest.add full_filename
    manifest.upload manifest.missing
    hash = manifest.manifest[full_filename]["hash"]
    client.command "file.download", "name" => file, "hash" => hash
  end

  def remove_file(dir, file, client)
    return if ignore_file?(File.join(dir, file))
    client.command "file.delete", "name" => file
  end

  def ignore_file?(file)
    return true unless File.exists?(file)
    return true if File.stat(file).pipe?
    return true if file =~ /\.swp/
    return true if file =~ /\.anvil/
    false
  end

  def start_file_watcher(client, dir)
    Thread.new do
      listener = Listen.to(dir)
      listener.change do |modified, added, removed|
        modified.concat(added).each do |file|
          relative = file[dir.length+1..-1]
          upload_file dir, relative, client
        end
        removed.each do |file|
          relative = file[dir.length+1..-1]
          remove_file dir, relative, client
        end
      end
      listener.latency(1.5)
      listener.polling_fallback_message("")
      listener.force_polling(true)
      listener.start
    end
  end

  def start_console_server(client, dir)
    Thread.new do
      console_server = TCPServer.new(0)
      write_anvil_metadata dir, "console.port", console_server.addr[1]
      loop do
        Thread.start(console_server.accept) do |console_client|
          client.run("env TERM=xterm bash") do |ch|
            client.hookup ch, console_client
            client.on_close(ch) { console_client.close }
          end
        end
      end
    end
  end

  def start_http_tunnel(client, remote_port=5000, local_port=9000)
    Thread.new do
      http_tunnel = TCPServer.new(local_port)
      loop do
        Thread.start(http_tunnel.accept) do |tunnel_client|
          client.tunnel(remote_port) do |ch|
            client.hookup ch, tunnel_client
          end
        end
      end
    end
  end

end

class Heroku::Client::Rendezvous
  def fixup(data)
    data
  end
end

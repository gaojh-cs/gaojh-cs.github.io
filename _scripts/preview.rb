# frozen_string_literal: true

require "rbconfig"

Dir.chdir(File.expand_path("..", __dir__))
require "bundler/setup"

$stdout.sync = true

# Only the preview child loads this hook; normal Jekyll builds stay unchanged.
if ARGV == ["--serve"]
  require "jekyll"

  Jekyll::Hooks.register([:pages, :documents], :post_render) do |page|
    next unless page.output_ext == ".html"

    page.output = page.output.sub("</head>", <<~HTML)
      <script data-preview-reconnect>
        (() => {
          let disconnected = false;
          document.addEventListener("LiveReloadDisconnect", () => {
            disconnected = true;
          });
          document.addEventListener("LiveReloadConnect", () => {
            if (disconnected) window.location.reload();
          });
        })();
      </script>
      </head>
    HTML
  end

  ARGV.replace(["serve", "--host", "127.0.0.1", "--port", "4000", "--livereload"])
  load Gem.bin_path("jekyll", "jekyll")
  exit
end

abort "Usage: ruby _scripts/preview.rb" unless ARGV.empty?

def start_preview
  options = {}
  options[:new_pgroup] = true if Gem.win_platform?
  Process.spawn(RbConfig.ruby, File.expand_path(__FILE__), "--serve", options)
end

def stop_preview(pid)
  return unless pid

  # Jekyll runs directly in this Ruby child; stop only the PID we spawned.
  Process.kill(Gem.win_platform? ? "KILL" : "TERM", pid)
  Process.waitpid(pid)
rescue Errno::ESRCH, Errno::ECHILD
  # The child may already have exited.
end

def clock
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

running = true
Signal.trap("INT") { running = false }
Signal.trap("TERM") { running = false }

loaded_config = File.binread("_config.yml")
observed_config = loaded_config
changed_at = clock
exit_code = 0
pid = nil

begin
  puts "Preview: http://127.0.0.1:4000/"
  puts "Watching _config.yml; configuration changes restart Jekyll automatically."
  puts "Press Ctrl+C to stop."
  pid = start_preview

  while running
    sleep 0.5
    break unless running

    if Process.waitpid(pid, Process::WNOHANG)
      exit_code = $?.exitstatus || 1
      pid = nil
      warn "Jekyll stopped. Check the message above, then run the preview again."
      break
    end

    begin
      current_config = File.binread("_config.yml")
    rescue Errno::ENOENT
      next # Editors may briefly remove the file during an atomic save.
    end

    if current_config != observed_config
      observed_config = current_config
      changed_at = clock
    end
    next if current_config == loaded_config || clock - changed_at < 1.0

    puts "_config.yml changed; restarting Jekyll..."
    stop_preview(pid)
    pid = nil
    loaded_config = current_config
    pid = start_preview
  end
ensure
  stop_preview(pid)
end

exit exit_code

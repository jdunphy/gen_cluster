require "socket"

def root
  File.dirname(__FILE__)  + "/../../"
end

SERVER   = "example_cluster_srv1@#{Socket.gethostname}"

namespace :server do
  1.upto(4) do |i|
    desc "start server #{i}"
    task "start#{i}" => [".erlang.cookie", :compile] do
      stop = ENV['STOP'] ? " -s init stop " : ""
      sh %Q{GPROC_SEEDS=#{SERVER} \
erl -pa #{root}/ebin -pa #{root}/test/ebin -pa #{root}/deps/*/ebin \
-name "example_cluster_srv#{i}@#{Socket.gethostname}" \
-setcookie abc \
+W w \
-boot start_sasl \
-s reloader \
-s example_cluster_srv start \
#{stop}
      }, :verbose => true
    end
  end
end

file ".erlang.cookie" do
  sh "echo 'acookiechangeme1234' > .erlang.cookie"
end

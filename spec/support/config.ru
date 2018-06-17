# Rack Servlets

ServerSentEventServlet = Proc.new { |env|
  body = Enumerator.new do |env|
    first_lines =  <<LINES
event: put
data: hello
data: world!

LINES
    env.yield(first_lines)

    sleep 1
    second_lines =  <<LINES
event: patch
data: YHOO
data: +2
data: 10

LINES
    env.yield(second_lines)

    sleep 8
    third_lines =  <<LINES
event: delete
data: bye!

LINES
    env.yield(third_lines)
  end

  [200, {"Content-Type" => "text/event-stream; charset=utf-8"}, body]
}

run Rack::URLMap.new({
  "/healthcheck" => Proc.new { |env| [200, {"Content-Length" => "5"}, ["Ready"]] },
  "/invalid-sdk-key" => Proc.new { |env| [401, {"Content-Type" => "text/event-stream"}, []] },
  "/internal-server-error" => Proc.new { |env| [500, {"Content-Type" => "text/event-stream"}, []] },
  "/missing-content-type" => Proc.new { |env| [200, {}, []] },
  "/invalid-content-type" => Proc.new { |env| [200, {"Content-Type" => "text/html; charset=utf-8"}, []] },
  "/sse" => ServerSentEventServlet,
})

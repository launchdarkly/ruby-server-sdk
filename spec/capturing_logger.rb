require "stringio"

class CapturingLogger
  def initialize
    @output = StringIO.new
    @logger = Logger.new(@output)
  end

  def output
    @output.string
  end

  def method_missing(meth, *args, &block)
    @logger.send(meth, *args, &block)
  end
end

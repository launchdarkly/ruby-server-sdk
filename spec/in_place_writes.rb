#
# Rewrites files the way applications and editors often do: in place, which is not atomic. The file
# is truncated first, and the new content is written after a pause, so that a reader in between
# finds the file empty, as it can with an application's writes, instead of only by chance.
#
module InPlaceWrites
  #
  # Truncates the file, waits for the pause, then writes the content. A file that does not exist
  # is created empty first.
  #
  # @param path [String]
  # @param content [String]
  # @param pause [Numeric] seconds between truncating the file and writing the content
  #
  def self.rewrite(path, content, pause)
    # Opening with "w" truncates the file at once.
    File.open(path, "w") do |file|
      sleep pause
      file.write(content)
    end
  end
end

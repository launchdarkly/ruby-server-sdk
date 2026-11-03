#
# Rewrites files the way applications and editors often do: in place, which is not atomic. The file
# is truncated first, and the new content is written after a pause, so that a reader in between
# finds the file empty, as it can with an application's writes, instead of only by chance.
#
module InPlaceWrites
  #
  # Truncates the file, writes the first part of the content if one is given, waits for the pause,
  # then writes the rest. A file that does not exist is created first.
  #
  # @param path [String]
  # @param content [String]
  # @param pause [Numeric] seconds between truncating the file and writing the rest of the content
  # @param first [String] the beginning of the content, which a reader can see during the pause
  #
  def self.rewrite(path, content, pause, first: "")
    raise ArgumentError, "the content must start with the first part" unless content.start_with?(first)

    # Opening with "w" truncates the file at once.
    File.open(path, "w") do |file|
      unless first.empty?
        file.write(first)
        file.flush
      end
      sleep pause
      file.write(content[first.length..])
    end
  end
end

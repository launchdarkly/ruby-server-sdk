require "ldclient-rb/reference"

describe LaunchDarkly::Reference do
  subject { LaunchDarkly::Reference }

  it "determines invalid formats" do
    [
      # Empty reference failures
      [nil, 'empty reference'],
      ["", 'empty reference'],
      ["/", 'empty reference'],

      # Double or trailing slashes
      ["//", 'double or trailing slash'],
      ["/a//b", 'double or trailing slash'],
      ["/a/b/", 'double or trailing slash'],

      # Invalid escape sequence
      ["/a~x", 'invalid escape sequence'],
      ["/a~", 'invalid escape sequence'],
      ["/a/b~x", 'invalid escape sequence'],
      ["/a/b~", 'invalid escape sequence'],

    ].each do |(path, msg)|
      ref = subject.create(path)
      expect(ref.raw_path).to eq(path)
      expect(ref.error).to eq(msg)
    end
  end

  describe "can handle valid formats" do
    it "can process references without a leading slash" do
      %w[key kind name name/with/slashes name~0~1with-what-looks-like-escape-sequences].each do |path|
        ref = subject.create(path)

        expect(ref.raw_path).to eq(path)
        expect(ref.error).to be_nil
        expect(ref.depth).to eq(1)
      end
    end

    it "can handle simple references with a leading slash" do
      [
        ["/key", :key],
        ["/0", :"0"],
        ["/name~1with~1slashes~0and~0tildes", :"name/with/slashes~and~tildes"],
      ].each do |(path, component)|
        ref = subject.create(path)

        expect(ref.raw_path).to eq(path)
        expect(ref.error).to be_nil
        expect(ref.depth).to eq(1)
        expect(ref.component(0)).to eq(component)
      end
    end

    it "can access sub-components of varying depths" do
      [
        ["key", 1, 0, :key],
        ["/key", 1, 0, :key],

        ["/a/b", 2, 0, :a],
        ["/a/b", 2, 1, :b],

        ["/a~1b/c", 2, 0, :"a/b"],
        ["/a~0b/c", 2, 0, :"a~b"],

        ["/a/10/20/30x", 4, 1, :"10"],
        ["/a/10/20/30x", 4, 2, :"20"],
        ["/a/10/20/30x", 4, 3, :"30x"],

        # invalid arguments don't cause an error, they just return nil
        ["", 0, 0, nil],
        ["", 0, -1, nil],

        ["key", 1, -1, nil],
        ["key", 1, 1, nil],

        ["/key", 1, -1, nil],
        ["/key", 1, 1, nil],

        ["/a/b", 2, -1, nil],
        ["/a/b", 2, 2, nil],
      ].each do |(path, depth, index, component)|
        ref = subject.create(path)
        expect(ref.depth).to eq(depth)
        expect(ref.component(index)).to eq(component)
      end
    end
  end

  describe "creating literal references" do
    it "can create valid references" do
      [
        ["name", "name"],
        ["a/b", "a/b"],
        ["/a/b~c", "/~1a~1b~0c"],
        ["/", "/~1"],
      ].each do |(literal, path)|
        expect(subject.create_literal(literal).raw_path).to eq(subject.create(path).raw_path)
      end
    end

    it("can detect invalid references") do
      [nil, "", true].each do |value|
        expect(subject.create_literal(value).error).to eq('empty reference')
      end
    end
  end
end

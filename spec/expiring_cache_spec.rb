require 'timecop'

describe LaunchDarkly::ExpiringCache do
  subject { LaunchDarkly::ExpiringCache }

  before(:each) do
    Timecop.freeze(Time.now)
  end

  after(:each) do
    Timecop.return
  end

  it "evicts entries based on TTL" do
    c = subject.new(3, 300)
    c[:a] = 1
    c[:b] = 2

    Timecop.freeze(Time.now + 330)

    c[:c] = 3

    expect(c[:a]).to be nil
    expect(c[:b]).to be nil
    expect(c[:c]).to eq 3
  end

  it "evicts entries based on max size" do
    c = subject.new(2, 300)
    c[:a] = 1
    c[:b] = 2
    c[:c] = 3

    expect(c[:a]).to be nil
    expect(c[:b]).to eq 2
    expect(c[:c]).to eq 3
  end

  it "does not reset LRU on get" do
    c = subject.new(2, 300)
    c[:a] = 1
    c[:b] = 2
    c[:a]
    c[:c] = 3

    expect(c[:a]).to be nil
    expect(c[:b]).to eq 2
    expect(c[:c]).to eq 3
  end

  it "resets LRU on put" do
    c = subject.new(2, 300)
    c[:a] = 1
    c[:b] = 2
    c[:a] = 1
    c[:c] = 3

    expect(c[:a]).to eq 1
    expect(c[:b]).to be nil
    expect(c[:c]).to eq 3
  end

  it "resets TTL on put" do
    c = subject.new(3, 300)
    c[:a] = 1
    c[:b] = 2

    Timecop.freeze(Time.now + 330)
    c[:a] = 1
    c[:c] = 3

    expect(c[:a]).to eq 1
    expect(c[:b]).to be nil
    expect(c[:c]).to eq 3
  end
end

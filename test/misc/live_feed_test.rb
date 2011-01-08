require "test/unit"
require "bgp/misc/live_feed"

class TestBgpMiscLiveFeed < Test::Unit::TestCase
  def test_feed
    feed = LiveFeed.open
    n=0
    loop do
      n+=1
      break if n>20
      msg_shex = feed.read.unpack('H*')[0]
      assert_match( /ff{16}....(02|04|05|01)/, msg_shex)
    end
    feed.close
  end
end
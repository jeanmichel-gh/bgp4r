require "test/unit"
require 'bgp4r'
require 'timeout'

Thread.abort_on_exception=true

class TestBgp < Test::Unit::TestCase
  
  include BGP

  Log.create
  Log.level=Logger::DEBUG
  
  N100 = Class.new(BGP::Neighbor)
  N300 = Class.new(BGP::Neighbor)

  class RecvMsgHandler
    def initialize(q)
      @q = q
    end
    def update(bgp_msg)
      @q.enq bgp_msg
    end
  end
  
  def setup
    @n100 = N100.new(:my_as=> 100, :remote_addr => '40.0.0.2', :local_addr => '40.0.0.1', :id=> '13.11.19.59')
    @n300 = N300.new(:my_as=> 300, :remote_addr => '40.0.1.1', :local_addr => '40.0.1.2', :id=> '13.11.19.57')
    start_peering
  end
  
  def test_verify_that_200_is_prepended_to_aspath
    assert @n100.is_established?, "Expected to be in Established state. <> #{@n100.state}"
    assert @n300.is_established?, "Expected to be in Established state. <> #{@n300.state}"
    queue = Queue.new
    @n300.add_observer RecvMsgHandler.new(queue)
    send_update_to @n100
    msg = recv(queue)
    assert msg, "Did not receive expected BGP update message."
    assert msg.path_attribute.has?(As_path)
    assert_not_nil msg.path_attribute[:as_path]
    assert_equal '200 100', msg.path_attribute[:as_path].as_path
  end

  def teardown
    [@n100, @n300].each { |n| n.stop }
    sleep(0.5)
  end
  
  private
  
  def start_peering
    [@n100, @n300].each { |n| 
      n.capability :as4_byte
      n.start 
    }
  end
  
  def recv(q, timeout=5)
    begin
       Timeout::timeout(timeout) do |t| 
         msg = q.deq
       end
     rescue Timeout::Error => e
       nil
     end
  end
  
  def update1
    update = Update.new(
      Path_attribute.new(
        Origin.new(0),
        Next_hop.new('40.0.0.1'),
        Multi_exit_disc.new(100),
        Local_pref.new(100),
        As_path.new(100),
        Communities.new('1311:1 311:59 2805:64')
      ),
      Nlri.new('77.0.0.0/17', '78.0.0.0/18', '79.0.0.0/19')
    )
  end

  def send_update_to(n)
    n.send_message update1
  end
  
end

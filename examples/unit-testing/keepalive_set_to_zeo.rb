require "test/unit"
require 'bgp4r'
require 'timeout'

Thread.abort_on_exception=true

class TestBgp < Test::Unit::TestCase
  
  include BGP

  Log.create
  Log.level=Logger::DEBUG
  
  N100 = Class.new(BGP::Neighbor)

  class RecvMsgHandler
    def initialize(q)
      @q = q
    end
    def update(bgp_msg)
      @q.enq bgp_msg
    end
  end
  
  def setup
    @n100 = N100.new(:my_as=> 100, :remote_addr => '40.0.0.2', :local_addr => '40.0.0.1', :id=> '13.11.19.59', :holdtime=>0)
    start_peering
  end
  
  def test_verify_that_200_is_prepended_to_aspath
    assert @n100.is_established?, "Expected to be in Established state. <> #{@n100.state}"
    queue = Queue.new
    @n300.add_observer RecvMsgHandler.new(queue)
  end

  def teardown
    [@n100].each { |n| n.stop }
    sleep(0.5)
  end
  
  private
  
  def start_peering
    [@n100].each { |n| 
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
  
  def send_update_to(n)
    n.send_message update1
  end
  
end

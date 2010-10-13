
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
    @n100 = N100.new(:my_as=> 100, :remote_addr => '40.0.0.2', :local_addr => '40.0.0.1', :id=> '13.11.19.59')
    start_peering
  end
  
  def test_verify_missing_well_known_attribute_is_greeting_with_a_notification_from_as200
    assert @n100.is_established?, "Expected to be in Established state. <> #{@n100.state}"
    queue = Queue.new
    @n100.add_observer RecvMsgHandler.new(queue)
    @n100.send_message malformed_update
    msg = recv(queue)
    assert msg, "Did not receive expected BGP update message."
    assert_instance_of(Notification, msg)
    assert_equal 'Missing Well-known Attribute', msg.to_string
    assert @n100.is_idle?
  end
  
  def teardown
    @n100.stop
    sleep(0.5)
  end
  
  private
  
  def start_peering
    @n100.capability :as4_byte
    @n100.start
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
    
  def malformed_update
     update = Update.new(
       Path_attribute.new(
         Origin.new(0),
         Multi_exit_disc.new(100),
         Local_pref.new(100),
         As_path.new(100)
       ),
       Nlri.new('77.0.0.0/17', '78.0.0.0/18', '79.0.0.0/19')
     )
   end
    
end

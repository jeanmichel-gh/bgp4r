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
    def update(m)
      @q.enq m if m.is_an_update?
    end
  end
  
  def setup
    @n100 = N100.new(:my_as=> 100, :remote_addr => '40.0.0.2', :local_addr => '40.0.0.1', :id=> '13.11.19.59')
    @n300 = N300.new(:my_as=> 300, :remote_addr => '40.0.1.1', :local_addr => '40.0.1.2', :id=> '13.11.19.57')
    start_peering
  end
  
  def test_verify_that_route_a_route_with_no_export_community_set_is_not_advertised
    assert @n100.is_established?, "Expected to be in Established state. <> #{@n100.state}"
    assert @n300.is_established?, "Expected to be in Established state. <> #{@n300.state}"
    queue = Queue.new
    @n300.add_observer RecvMsgHandler.new(queue)
    
    # advertise a bunch of routes and verity they are advertised as expected.
    @n100.send_message an_exportable_update
    msg = recv(queue)
    assert msg, "Did not receive expected BGP update message."
    assert msg.path_attribute.has_a_communities_attr?, "It should have contained a COMMUNITY attribute."
    assert msg.path_attribute[:communities].has?('1311:1'), "It should have contained community 1311:11."
    
    # send it again with no_export set.
    # we should be asked to withdraw the previously advertise routes.
    @n100.send_message a_non_exportable_update 
    msg = recv(queue)
    assert(msg)
    assert msg.is_an_update? 
    assert msg.has_no_path_attribute?, "We should have received a route withdrawal with previous advertised routes."    
    assert_equal "77.0.0.0/17\n78.0.0.0/18\n79.0.0.0/19", msg.withdrawn.to_s

    # send it again, this time nothing to withdraw, hence no update to receive.
    @n100.send_message a_non_exportable_update 
    msg = recv(queue)
    assert_nil(msg)    

    # advertise yet again without no_export and we shall receive an update from n300
    @n100.send_message an_exportable_update
    msg = recv(queue)
    assert msg, "Did not receive expected BGP update message."
    assert msg.path_attribute.has_a_communities_attr?, "It should have contained a COMMUNITY attribute."
    assert msg.path_attribute[:communities].has?('1311:1'), "It should have contained community 1311:11."
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
  
  def an_exportable_update
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
  
  def a_non_exportable_update
    update = an_exportable_update.clone
    update.path_attribute[:communities].add(:no_export)
    update
  end

end

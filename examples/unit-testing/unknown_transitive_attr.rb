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
    @n100.capability :mbgp, :ipv4, :unicast
    gr = Graceful_restart_cap.new 3, 120
    gr.add :ipv4, :unicast, 1
    gr.add :ipv4, :multicast, 1
    gr.add :ipv6, :unicast, 1
    gr.add :ipv6, :multicast, 3
    @n100.capability gr
    start_peering
  end
  
  def test_unknown_transitive_attribute
    assert @n100.is_established?, "Expected to be in Established state. <> #{@n100.state}"
    assert @n300.is_established?, "Expected to be in Established state. <> #{@n300.state}"
    queue = Queue.new
    @n300.add_observer RecvMsgHandler.new(queue)
    @n100.send_message update_with_unknown_transitive_attribute
    msg = recv(queue)
    assert msg, "Did not receive expected BGP update message."
    assert msg.path_attribute.has?(255), "The path attribute was expected to contain an attribute type 255"
    assert_not_nil msg.path_attribute[255]
    assert_equal 'AN OPTIONAL TRANSITIVE ATTR WITH TYPE 255', msg.path_attribute[255].value
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
  
  def update_with_unknown_transitive_attribute
    my_attr = Class.new(Attr)
    my_attr.class_eval do
      attr_reader :type, :flags, :value
      attr_writer :value
      def initialize(*args)
        if args.size>1
          @flags, @type,	@value = args
        else
          arr = parse(*args)
        end
      end
      def parse(s)
        @flags, @type, len, @value = super
      end
      def encode
        super(value)
      end
    end
    update = Update.new(
      Path_attribute.new(
      Next_hop.new('40.0.0.1'),
      Origin.new(0),
      Multi_exit_disc.new(100),
      Local_pref.new(100),
      As_path.new(100),
      my_attr.new(ATTR::OPTIONAL_TRANSITIVE, 255, 'AN OPTIONAL TRANSITIVE ATTR WITH TYPE 255'),
      my_attr.new(ATTR::OPTIONAL_TRANSITIVE, 0, 'AN OPTIONAL TRANSITIVE ATTR WITH TYPE 0')
    ),
    Nlri.new('77.0.0.0/17', '78.0.0.0/18', '79.0.0.0/19')
    )
  end
  
end

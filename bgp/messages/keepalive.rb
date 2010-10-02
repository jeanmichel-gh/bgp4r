# KEEPALIVE Message Format
# 
#    BGP does not use any TCP-based, keep-alive mechanism to determine if
#    peers are reachable.  Instead, KEEPALIVE messages are exchanged
#    between peers often enough not to cause the Hold Timer to expire.  A
#    reasonable maximum time between KEEPALIVE messages would be one third
#    of the Hold Time interval.  KEEPALIVE messages MUST NOT be sent more
#    frequently than one per second.  An implementation MAY adjust the
#    rate at which it sends KEEPALIVE messages as a function of the Hold
#    Time interval.
# 
#    If the negotiated Hold Time interval is zero, then periodic KEEPALIVE
#    messages MUST NOT be sent.
# 
#    A KEEPALIVE message consists of only the message header and has a
#    length of 19 octets.
#

require 'bgp/messages/message'

module BGP
  class Keepalive < Message
    def initialize
      @msg_type=KEEPALIVE
    end
    def to_s
      "Keepalive Message (#{MESSAGE::KEEPALIVE}), length: 19" + ", [#{self.to_shex[32..-1]}]"
    end
  end
end

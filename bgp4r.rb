
#if Object.const_defined? :Encoding
#  Encoding.default_external="BINARY"
#  Encoding.default_internal="BINARY"
#end

require 'bgp/common'
require 'bgp/iana'
require 'bgp/messages/messages'
require 'bgp/path_attributes/attributes'
require 'bgp/nlris/nlris'
require 'bgp/optional_parameters/capabilities'
require 'bgp/neighbor/neighbor'

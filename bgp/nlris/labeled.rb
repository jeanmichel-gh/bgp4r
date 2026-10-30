require 'bgp/nlris/label'
require 'bgp/nlris/registry'
module BGP
  class Labeled

    # withdrawn: the NLRI came from MP_UNREACH_NLRI, which is where RFC
    # 8277 section 2.4 says a withdrawal travels, so the three octets
    # where a label would be are its Compatibility field. Nothing in the
    # octets says so, which is why it has to be passed in; see the comment
    # on Label_stack#compatibility.
    def self.new_ntop(s, afi, safi, path_id=nil, withdrawn=false)
      nlri = new(s, afi, safi, withdrawn)
      nlri.path_id=path_id if path_id
      nlri
    end
    
    def self.new_with_path_id(path_id, *args)
      l = new(*args)
      l.path_id=path_id
      l
    end
    
    def initialize(*args)
      if args.size>0 and args[0].is_a?(String) and args[0].is_packed?
        parse(*args)
      elsif args.size==1 and args[0].is_a?(Hash)
        # TODO: a new_prefix :prefix=>, :labels=>
        #                    :other=> ...
        @prefix = Prefix.new(args[0][:prefix]) # assuming it's a Prefix, which it may not be
        # A withdrawal hashes a :compatibility key instead of :labels, so
        # the hash a parsed withdrawal produces builds one back.
        @labels = if args[0][:compatibility]
                    Label_stack.new(:compatibility => args[0][:compatibility])
                  else
                    Label_stack.new(*args[0][:labels])
                  end
      else
        @prefix, *labels = args
        @labels = Label_stack.new(*labels)
      end
    end
    #FIXME... a mixin path_id ????
    def path_id
      @prefix.path_id
    end
    def path_id=(val)
      @prefix.path_id=val
    end
    def bit_length
      @labels.bit_length+@prefix.bit_length
    end
    def encode
      s = [bit_length, @labels.encode, @prefix.encode_without_len_without_path_id].pack('Ca*a*')
      if path_id
        [path_id, s].pack('Na*')
      else
        s
      end
    end
    def to_hash
      @labels.to_hash.merge(@prefix.to_hash)
    end
    def to_s
      "#{@labels} #{@prefix}"
    end
    def afi
      @prefix.afi
    end  
    def parse(s, afi=1, safi=1, withdrawn=false)
      bitlen = s.slice!(0,1).unpack('C')[0]
      @labels = Label_stack.new(s, withdrawn)
      # RFC 8277 section 2.4 on a withdrawal: "the length of the
      # Compatibility field must be subtracted from the length of the
      # NLRI", which is this subtraction with a size of 1. Reading the
      # field as labels made the walk eat the prefix too and left this at
      # zero, so the prefix came out 0.0.0.0/0.
      mlen = bitlen - (24*@labels.size)
      prefix = [mlen,s.slice!(0,(mlen+7)/8)].pack("Ca*")
      case safi
      when 128,129
        #FIXME: implement Vpn.new_ntop
        @prefix = Vpn.new(prefix, afi)
      else
        @prefix = Prefix.new_ntop(prefix, afi)
      end
    end
  end

end

# SAFI 4, labeled unicast (RFC 8277), and SAFI 128 and 129, the VPN
# families (RFC 4364), whose NLRI is a label stack in front of a prefix
# and, for the VPN ones, a Route Distinguisher in front of that. The
# withdrawn flag reaches only these, because they are the only families
# whose NLRI carries a label for RFC 8277 section 2.4 to replace.
#
# Vpn and Rd load after this file, so both are named inside the blocks
# and resolved when a block runs rather than when this file loads.
module BGP
  class Labeled
    # What MpReachCommon#labels_from was. It reads a build hash, so it
    # belongs with the families that take labels.
    def self.labels_from(n)
      return [{ :compatibility => n[:compatibility] }] if n[:compatibility]
      [n[:label]].flatten.compact
    end
  end

  Nlri_registry.register_parse([4, 128, 129]) do |s, afi, safi, path_id, withdrawn|
    Labeled.new_ntop(s, afi, safi, path_id, withdrawn)
  end

  Nlri_registry.register_build(4) do |nlris, _afi, _safi, path_id|
    [nlris].flatten.compact.collect do |n|
      pid = n[:path_id] || path_id
      prefix = n[:prefix].is_a?(String) ? Prefix.new(n[:prefix]) : n[:prefix]
      Labeled.new_with_path_id(pid, prefix, *Labeled.labels_from(n))
    end
  end

  Nlri_registry.register_build([128, 129]) do |nlris, _afi, _safi, path_id|
    [nlris].flatten.compact.collect do |n|
      pid = n[:path_id] || path_id
      prefix = n[:prefix].is_a?(Prefix) ? n[:prefix] : Prefix.new(n[:prefix])
      rd = n[:rd].is_a?(Rd) ? n[:rd] : Rd.new(*n[:rd])
      Labeled.new_with_path_id(pid, Vpn.new(prefix, rd), *Labeled.labels_from(n))
    end
  end
end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
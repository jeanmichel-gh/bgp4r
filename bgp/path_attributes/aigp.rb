require 'bgp/path_attributes/attribute'

module BGP

  # RFC 7311 section 3: the value of the AIGP attribute is a set of TLVs.
  # Each TLV is Type (1 octet), Length (2 octets, counts the 3 header
  # octets) and Value. Only type 1, the AIGP TLV, is defined. Its length
  # is 11 and its value is an 8 octet metric.
  #
  # The attribute keeps every TLV as raw bytes, in wire order, so encode
  # writes back exactly what was parsed or built. The metric is taken
  # from the first type 1 TLV with length 11 (RFC 7311 section 3: only
  # the first AIGP TLV is used, the others are passed along unchanged).
  # Unknown types, extra AIGP TLVs and malformed or truncated TLVs are
  # kept as they are. Encode never validates, so malformed attributes
  # can be built for testing.
  #
  # When there is no valid AIGP TLV, to_i returns 0 and has_metric?
  # returns false.
  #
  #   Aigp.new(100)                          # one AIGP TLV
  #   Aigp.new(100).add_tlv(9, "\x01\x02")   # plus a TLV of type 9
  #   Aigp.new(:tlvs=>[]).add_tlv(1, '')     # only a type 1 TLV of length 3
  #   Aigp.new(:tlvs=>['090003'])            # TLVs given as hex strings
  #   Aigp.new(100).add_tlv(1, '', :length=>11)  # a truncated AIGP TLV
  #
  class Aigp < Attr

    AIGP_TLV = 1
    AIGP_TLV_LENGTH = 11

    def initialize(*args)
      @flags, @type = OPTIONAL_NON_TRANSITIVE, ACCUMULATED_IGP_METRIC
      @tlvs = []
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode, *args[1..-1])
      elsif args.size==1 and args[0].is_a?(Integer)
        @tlvs << aigp_tlv(args[0])
      elsif args.size==1 and args[0].is_a?(Hash) and args[0].has_key?(:aigp)
        initialize(args[0][:aigp])
      elsif args.size==1 and args[0].is_a?(Hash)
        tlvs = args[0][:tlvs] || args[0]['tlvs'] || []
        @tlvs = tlvs.collect { |t| [t].pack('H*') }
      elsif args.empty?
        @tlvs << aigp_tlv(0)
      else
        raise ArgumentError, "invalid argument: #{args.inspect}"
      end
    end

    # Appends a TLV. value is a binary String. length defaults to the
    # value size plus 3. Pass another length to build a malformed TLV.
    def add_tlv(type, value='', length: nil)
      value = value.b
      length ||= value.size + 3
      @tlvs << ([type, length].pack('Cn') + value)
      self
    end

    # The TLVs as raw binary Strings, in wire order.
    def tlvs
      @tlvs.dup
    end

    def has_metric?
      ! metric_tlv.nil?
    end

    def to_i
      tlv = metric_tlv
      return 0 unless tlv
      high, low = tlv.unpack('x3NN')
      (high << 32) + low
    end

    def to_hash
      if plain?
        {:aigp=> to_i}
      else
        {:aigp=> {:tlvs=> @tlvs.collect { |t| t.unpack('H*')[0] }}}
      end
    end

    def accumulated_igp_metric
      if has_metric?
        format("(0x%8.8x) %d", to_i, to_i)
      else
        'none'
      end
    end
    alias metric accumulated_igp_metric

    def to_s(method=:default)
      super(accumulated_igp_metric, method)
    end

    def encode
      super(@tlvs.inject(String.new.b) { |s, t| s << t })
    end

    # RFC 7311 section 3 and 3.2: TLVs of unknown types and more than one
    # AIGP TLV do not make the attribute malformed. Never raise here: a
    # TLV with a length below 3 or longer than what is left, or a tail
    # shorter than a TLV header, is kept as one raw entry.
    def parse(s)
      @flags, @type, _, value=super(s)
      @tlvs = []
      value = value.b
      until value.empty?
        len = value.size >= 3 ? value.unpack('xn')[0] : 0
        len = value.size if len < 3 or len > value.size
        @tlvs << value.slice!(0, len)
      end
    end

    private

    def aigp_tlv(metric)
      [AIGP_TLV, AIGP_TLV_LENGTH, metric >> 32, metric & 0xffffffff].pack('CnNN')
    end

    def metric_tlv
      @tlvs.find { |t| t.size == AIGP_TLV_LENGTH and t.unpack('Cn') == [AIGP_TLV, AIGP_TLV_LENGTH] }
    end

    def plain?
      @tlvs.size == 1 and has_metric?
    end

  end

  class Aigp
    class << self
      def new_hash(_arg={})
        arg = {:aigp=>0}.merge(_arg)
        new arg[:aigp]
      end
    end
  end


end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

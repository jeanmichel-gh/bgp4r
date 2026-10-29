require "test/unit"

require "bgp/nlris/labeled"
require 'bgp/nlris/prefix'
require 'bgp/nlris/vpn'
require 'bgp/nlris/rd'

class TestBgpNlrisLabeled < Test::Unit::TestCase
  include BGP
  def test_new
    assert_equal('Label Stack=100 (bottom) 10.0.0.0/8',  Labeled.new(Prefix.new('10.0.0.1/8'), 100).to_s)
    assert_equal('Label Stack=100,101 (bottom) 10.0.0.0/8',  Labeled.new(Prefix.new('10.0.0.1/8'), 100,101).to_s)
    assert_equal('Label Stack=100,101,102 (bottom) 10.0.0.0/8',  Labeled.new(Prefix.new('10.0.0.1/8'), 100,101,102).to_s)
    assert_equal('200006410a',  Labeled.new(Prefix.new('10.0.0.1/8'), 100).to_shex)
    assert_equal('380006400006510a',  Labeled.new(Prefix.new('10.0.0.1/8'), 100,101).to_shex)
    assert_equal('500006400006500006610a',  Labeled.new(Prefix.new('10.0.0.1/8'), 100,101,102).to_shex)
    assert_equal({:prefix=>"10.0.0.0/8", :labels=>[100, 101, 102]}, Labeled.new(Prefix.new('10.0.0.1/8'), 100,101,102).to_hash)
    labeled = Labeled.new(Prefix.new('10.0.0.1/8'), 100,101,102)
    assert_equal(labeled.to_shex, Labeled.new(labeled.to_hash).to_shex)
    assert_equal({:prefix=>"10.0.0.0/8", :labels=>[100, 101, 102]}, Labeled.new(Prefix.new('10.0.0.1/8'), 100,101,102).to_hash)
    #FIXME: add labeled  and labeled vpn tests
  end
  def test_new_ntop
    assert_equal('Label Stack=100 (bottom) 10.0.0.0/8', Labeled.new_ntop(['200006410a'].pack('H*'), 1, 1).to_s)
    assert_equal('Label Stack=100,101 (bottom) 10.0.0.0/8', Labeled.new_ntop(['380006400006510a'].pack('H*'), 1, 1).to_s)
    assert_equal('Label Stack=100,101,102 (bottom) 10.0.0.0/8', Labeled.new_ntop(['500006400006500006610a'].pack('H*'), 1, 1).to_s)
    assert_equal('200006410a', Labeled.new_ntop(['200006410a'].pack('H*'), 1, 1).to_shex)
    assert_equal('380006400006510a', Labeled.new_ntop(['380006400006510a'].pack('H*'), 1, 1).to_shex)
    assert_equal('500006400006500006610a', Labeled.new_ntop(['500006400006500006610a'].pack('H*'), 1, 1).to_shex)
    #FIXME: add labeled  and labeled vpn tests
  end
  def test_new_afi_1_safi_128_rd_0_0
    lb = Labeled.new_ntop(['580064b10000006405591311'].pack('H*'), 1, 128)
    assert_equal('580064b10000006405591311', lb.to_shex)
    assert_equal('Label Stack=1611 (bottom) RD=100:89723665, IPv4=0.0.0.0/0', lb.to_s)
    assert_equal({:rd=>[100, 89723665], :label=>1611}, lb.to_hash)
  end
  def test_new_ntop_path_id
    # RFC 7911 section 3: a 4 byte path id is prepended to the NLRI.
    # RFC 8277 section 2: the labeled NLRI is length, label, prefix.
    lb = Labeled.new_ntop(['200006410a'].pack('H*'), 1, 1, 7)
    assert_equal(7, lb.path_id)
    assert_equal('00000007200006410a', lb.to_shex)
  end
  def test_path_id_rd_only_vpn
    # Labeled VPN with RD 0:0 and no prefix: no path id, still encodes.
    lb = Labeled.new(Vpn.new(Rd.new), 100)
    assert_nil(lb.path_id)
    # 24 label bits + 64 RD bits = 88 (0x58), RFC 8277 section 2.
    assert_equal('58000641' + '00' * 8, lb.to_shex)
  end
  def test_path_id_does_not_hide_errors
    broken = Object.new
    def broken.path_id ; raise ArgumentError, 'broken' ; end
    lb = Labeled.new(Prefix.new('10.0.0.0/8'), 100)
    lb.instance_variable_set(:@prefix, broken)
    assert_raise(ArgumentError) { lb.path_id }
  end


  # A withdrawal as RFC 8277 section 2.4 asks for it: the label of a
  # withdrawn route is replaced by a Compatibility field that "SHOULD be
  # set to 0x800000", whose Bottom of Stack bit is 0. bgp4r could not read
  # one at all. Label_stack#parse took that bit as "another entry follows",
  # read on into the prefix octets and off the end, and raised
  # NoMethodError on nil; a peer withdrawing a labeled route could stop
  # bgp4r reading the UPDATE.
  #
  # The length octet counts the label field and the prefix: 24 bits of
  # Compatibility field and 8 of 10.0.0.0/8 is 32, 0x20.
  def test_a_withdrawal_carrying_the_compatibility_field_is_read_and_written_back
    hex = '20' + '800000' + '0a'
    lb = BGP::Labeled.new([hex].pack('H*').is_packed, 1, 4)
    assert_equal('10.0.0.0/8', lb.to_hash[:prefix])
    assert_equal(hex, lb.to_shex)
  end

  # And an ordinary labeled route is untouched, with one label or two.
  def test_an_ordinary_labeled_route_still_round_trips
    { '30' + '000641' + '0a0000'            => 'Label Stack=100 (bottom) 10.0.0.0/24',
      '48' + '000640' + '000651' + '0a0000' => 'Label Stack=100,101 (bottom) 10.0.0.0/24',
    }.each do |hex, text|
      lb = BGP::Labeled.new([hex].pack('H*').is_packed, 1, 4)
      assert_equal(text, lb.to_s, hex)
      assert_equal(hex, lb.to_shex, hex)
    end
  end

  # What the Bottom of Stack bit is for, and why reading a withdrawal
  # properly needs to know it is one. RFC 8277 section 2.2 says the bit
  # "MUST be set to one on transmission" so that a reader can find the end
  # of the stack; with it clear, these octets are ambiguous, and the only
  # thing the format offers is the bit. So a label whose bit is clear
  # followed by three octets of prefix reads as two labels and an empty
  # prefix, and the Compatibility field of a withdrawal, which is 0x800000
  # with the bit clear, reads the same way whenever the prefix is three
  # octets or more.
  #
  # Both come back byte for byte, which is what this pull request fixed, so
  # nothing is corrupted on the way out and a capture can be sent again.
  # Reading the Compatibility field as a Compatibility field needs the
  # knowledge that the NLRI came from MP_UNREACH_NLRI, which Labeled is not
  # given; that half is in CLAUDE.md under "Known issues to work on".
  def test_a_bit_clear_entry_before_a_prefix_is_ambiguous_and_still_round_trips
    { '30' + '000640' + '0a0000' => 'Label Stack=100,40960 (bottom) 0.0.0.0/0',
      '30' + '800000' + '0a0000' => 'Label Stack=524288,40960 (bottom) 0.0.0.0/0',
    }.each do |hex, text|
      lb = BGP::Labeled.new([hex].pack('H*').is_packed, 1, 4)
      assert_equal(text, lb.to_s, hex)
      assert_equal(hex, lb.to_shex, hex)
    end
  end

  # The bug this fixes, and the whole reason the withdrawal fact has to be
  # carried: 0x30 is 48 bits, 24 of label and 24 of prefix, and the three
  # octets where the label goes are the RFC 8277 section 2.4 Compatibility
  # field. Section 2.4 on the length: "the length of the Compatibility
  # field must be subtracted from the length of the NLRI".
  #
  # Read as a label the field's clear S bit let the walk run on, so it took
  # the prefix as a second label and left nothing: the whole NLRI came back
  # as 'Label Stack=524288,40960 (bottom) 0.0.0.0/0'.
  def test_a_withdrawn_labeled_nlri_reads_its_prefix
    hex = '308000000a0000'
    lb = Labeled.new([hex].pack('H*').is_packed, 1, 4, true)
    assert_equal('Compatibility=0x800000 10.0.0.0/24', lb.to_s)
    assert_equal(hex, lb.to_shex, 'byte for byte, so a capture can be sent again')
    assert_equal({ :compatibility => '800000', :prefix => '10.0.0.0/24' }, lb.to_hash)
    assert_equal(hex, Labeled.new(lb.to_hash).to_shex, 'and the hash builds it back')
  end

  # The same octets without that fact, which is what an announcement is.
  # Nothing in them distinguishes the two, so this is not a second bug to
  # fix but the reason Mp_unreach has to say which it is: a reader with
  # only the octets cannot know. Kept as a test so that stays visible.
  def test_the_same_octets_read_as_an_announcement_differ
    hex = '308000000a0000'
    lb = Labeled.new([hex].pack('H*').is_packed, 1, 4)
    assert_equal('Label Stack=524288,40960 (bottom) 0.0.0.0/0', lb.to_s)
  end

  # A withdrawal of a VPN prefix: the 8 RD octets of RFC 4364 section 4.2
  # sit behind the Compatibility field, so 0x70 is 112 bits of 24, 64 and
  # 24. This is the shape the capture in update_test.rb carries.
  def test_a_withdrawn_vpn_labeled_nlri
    hex = '708000010000000100000001' + '0a0101'
    lb = Labeled.new([hex].pack('H*').is_packed, 1, 128, true)
    assert_match(/\ACompatibility=0x800001 \(not the RECOMMENDED 0x800000\)/, lb.to_s)
    assert_match(/10\.1\.1\.0\/24\z/, lb.to_s)
    assert_equal(hex, lb.to_shex)
  end

end

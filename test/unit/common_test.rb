#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of BGP4R.
# 
# BGP4R is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# BGP4R is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with BGP4R.  If not, see <http://www.gnu.org/licenses/>.
#++

require "bgp/common"

require 'test/unit'
require 'tmpdir'
require 'stringio'
class Common_Test < Test::Unit::TestCase
  # A stand in for a path attribute: to_shex and to_shex4 only care that
  # encode and encode4 answer with wire bytes.
  class Encoded
    def initialize(hex, hex4)
      @hex, @hex4 = hex, hex4
    end
    def encode(*args)
      [@hex].pack('H*')
    end
    def encode4(*args)
      [@hex4].pack('H*')
    end
  end
  # IPAddr#mlen used to never return for a prefix of length 0, so a plain
  # call to it would wedge the whole suite rather than fail one test. Run
  # it in a thread and give up on it, so the bug coming back reads as a
  # failure here.
  def mlen_within(seconds, *addresses)
    values = nil
    t = Thread.new { values = addresses.collect { |a| IPAddr.new(a).mlen } }
    assert(t.join(seconds),
           "IPAddr#mlen did not return within #{seconds}s for #{addresses.inspect}")
    values
  ensure
    t.kill if t
  end
  def test_array_pack_returns_a_packed_string
    s = [1,2,3].pack('C*')
    assert(s.is_packed?)
    assert( ! "1234".is_packed?)
  end
  def test_is_packed_marks_a_string
    s = String.new('0001')
    assert( ! s.is_packed?)
    assert_same(s, s.is_packed)
    assert(s.is_packed?)
    assert(s.packed?)
  end
  def test_ipaddr_create
    ip = IPAddr.new('10.0.0.1')
    assert_equal('0a000001', ip.to_shex)
    assert_equal('0a000001', IPAddr.create(ip.encode).to_shex)
    assert_equal('0a000001', IPAddr.create(ip.to_i).to_shex)
  end
  def test_ipaddr_create_from_a_byte_array
    # Four octets of an IPv4 address as they come off the wire.
    assert_equal('0a000001', IPAddr.create([10,0,0,1]).to_shex)
    assert_equal('10.0.0.1', IPAddr.create([10,0,0,1]).to_s)
    assert(IPAddr.create([10,0,0,1]).ipv4?)
    # Sixteen octets make an IPv6 address.
    v6 = IPAddr.create([0x20,0x01,0x0d,0xb8] + [0]*11 + [1])
    assert(v6.ipv6?)
    assert_equal('2001:db8::1', v6.to_s)
  end
  def test_ipaddr_create_edges
    assert_equal('00000000', IPAddr.create(0).to_shex)
    assert_equal('ffffffff', IPAddr.create(0xffffffff).to_shex)
    assert_equal('255.255.255.255', IPAddr.create(0xffffffff).to_s)
    assert_equal('0a000001', IPAddr.create('10.0.0.1').to_shex)
    assert_equal('20010db8000000000000000000000001', IPAddr.create('2001:db8::1').to_shex)
  end
  def test_netmask_comes_from_the_standard_library
    # ipaddr has had a compatible #netmask since Ruby 2.5, so the copy in
    # common.rb is guarded out on every Ruby bgp4r supports and never runs.
    # Assert that here, so a Ruby that drops #netmask is noticed in this
    # file rather than somewhere far away.
    assert(IPAddr.method_defined?(:netmask))
    path, = IPAddr.instance_method(:netmask).source_location
    assert_no_match(/bgp\/common\.rb\z/, path.to_s)
  end
  def test_common_defines_no_netmask_of_its_own
    # common.rb used to carry a copy of #netmask under an
    # `unless method_defined?(:netmask)` guard that is false on every Ruby
    # bgp4r supports, so the body never ran. The lines are gone; keep them
    # gone. test_netmask_comes_from_the_standard_library above is what
    # would notice a Ruby that drops the method.
    root = File.expand_path('../..', File.dirname(__FILE__))
    src = File.read(File.join(root, 'bgp', 'common.rb'))
    assert_no_match(/def\s+netmask/, src)
    assert_no_match(/method_defined\?\(:netmask\)/, src)
  end
  def test_ipaddr_mlen_of_a_zero_length_prefix
    # RFC 4271 section 4.3: a default route is a length of 0 and no prefix
    # octets. The mask has no set bit, so _mlen_ floors at 0 rather than
    # shifting zero forever.
    assert_equal([0, 0], mlen_within(10, '0.0.0.0/0', '::/0'))
    # Memoized, so the second call answers 0 too and does not re-run.
    assert_equal(0, IPAddr.new('0.0.0.0/0').mlen)
    v6 = IPAddr.new('::/0')
    assert_equal(0, v6.mlen)
    assert_equal(0, v6.mlen)
  end
  def test_ipaddr_mlen_of_a_full_length_prefix
    assert_equal([32, 32, 32], mlen_within(10, '10.0.0.1', '10.0.0.1/32', '255.255.255.255/32'))
    assert_equal([128, 128, 128], mlen_within(10, '::1', '2011:1:18::1', '2011:1:18::1/128'))
  end
  def test_ipaddr_mlen_agrees_with_the_standard_library_prefix
    # Every length, to pin that the floor at 0 moved nothing else.
    assert_equal((0..32).to_a, mlen_within(20, *(0..32).collect { |l| "10.1.2.3/#{l}" }))
    assert_equal((0..128).to_a, mlen_within(20, *(0..128).collect { |l| "2011:1:18::1/#{l}" }))
    (0..32).each { |l| assert_equal(IPAddr.new("10.1.2.3/#{l}").prefix, IPAddr.new("10.1.2.3/#{l}").mlen) }
    (0..128).each { |l| assert_equal(IPAddr.new("2011:1:18::1/#{l}").prefix, IPAddr.new("2011:1:18::1/#{l}").mlen) }
  end
  def test_my_caller_splits_a_caller_line_on_the_path_separator
    assert_equal(['', 'usr', 'lib', 'bgp', 'common.rb:20'],
                 my_caller('/usr/lib/bgp/common.rb:20'))
    assert_equal(['common.rb:20'], my_caller('common.rb:20'))
    assert_equal([], my_caller(''))
  end
  def test_to_shex_without_an_encode
    # Anything that cannot encode hexlifies to the empty string rather
    # than raising, because to_s of an attribute calls these blind.
    assert_equal('', Object.new.to_shex)
    assert_equal('', Object.new.to_s_hexlify)
    assert_equal('', Object.new.to_shex4)
    assert_equal('', Object.new.to_shex_len(20))
    assert_equal('', Object.new.to_shex4_len(20))
  end
  def test_to_shex4_uses_encode4
    # to_shex4 is the 4 byte AS form: it hexlifies encode4, not encode.
    e = Encoded.new('4002080203000100020003', '40020e0203000000010000000200000003')
    assert_equal('4002080203000100020003', e.to_shex)
    assert_equal('40020e0203000000010000000200000003', e.to_shex4)
    # An object with encode but no encode4 gets nothing from to_shex4.
    only2 = IPAddr.new('10.0.0.1')
    assert_equal('0a000001', only2.to_shex)
    assert_equal('', only2.to_shex4)
  end
  def test_to_shex_len_truncates_past_the_given_length
    e = Encoded.new('4002080203000100020003', '40020e0203000000010000000200000003')
    # s[0..len] keeps len+1 characters, then marks the cut.
    assert_equal('400208020300010002000...', e.to_shex_len(20))
    assert_equal('40020e020300000001000...', e.to_shex4_len(20))
    # Nothing to cut: the whole string, no ellipsis.
    assert_equal(e.to_shex, e.to_shex_len(200))
    assert_equal(e.to_shex4, e.to_shex4_len(200))
  end
  def test_ipaddr_netmask
    assert_equal(32, IPAddr.new('10.0.0.1').mlen)
    assert_equal(16, IPAddr.new('10.0.0.1/16').mlen)
    assert_equal(7, IPAddr.new('10.0.0.0/7').mlen)
    assert_equal(128, IPAddr.new('0::0').mlen)
    assert_equal(96, IPAddr.new('2004::0001:3/96').mlen)
    assert_equal('255.255.255.255', IPAddr.new('1.1.1.1').netmask)
    assert_equal('255.255.255.255', IPAddr.new('1.1.1.1/32').netmask)
    assert_equal('255.255.255.254', IPAddr.new('1.1.1.1/31').netmask)
    assert_equal('255.255.255.252', IPAddr.new('1.1.1.1/30').netmask)
    assert_equal('255.255.255.248', IPAddr.new('1.1.1.1/29').netmask)
    assert_equal('ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff',IPAddr.new('2011:1:18::1').netmask)
    assert_equal('ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe',IPAddr.new('2011:1:18::1/127').netmask)
    assert_equal('ffff:ffff:ffff:ffff:8000:0000:0000:0000',IPAddr.new('2011:1:18::1/65').netmask)
    assert_equal('ffff:ffff:ffff:ffff:0000:0000:0000:0000',IPAddr.new('2011:1:18::1/64').netmask)
    assert_equal('ffff:ffff:ffff:fffe:0000:0000:0000:0000',IPAddr.new('2011:1:18::1/63').netmask)
    assert_equal('ffff:ffff:ffff:0000:0000:0000:0000:0000',IPAddr.new('2011:1:18::1/48').netmask)
    assert_equal('ffff:ffff:0000:0000:0000:0000:0000:0000',IPAddr.new('2011:1:18::1/32').netmask)
    assert_equal('0.0.0.0', IPAddr.new('0.0.0.0/0').netmask)
    assert_equal('255.0.0.0', IPAddr.new('10.0.0.0/8').netmask)
    assert_equal('0000:0000:0000:0000:0000:0000:0000:0000',IPAddr.new('::/0').netmask)
  end
  def test_no_warnings_from_library_under_w
    require 'rbconfig'
    root = File.expand_path('../..', File.dirname(__FILE__))
    ruby = File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'])
    out = IO.popen([ruby, '-w', "-I#{root}", '-e', 'require "bgp4r"', :err => [:child, :out]]) { |io| io.read }
    bgp_dir = File.join(root, 'bgp') + '/'
    warnings = out.lines.select { |l| l.include?(bgp_dir) }
    assert_equal([], warnings)
  end
  def test_logger_is_declared
    # common.rb requires 'logger'. Ruby 4.0 made it a bundled gem, so under
    # Bundler it loads only when declared. Read the files as text: loading
    # the gemspec runs git, which the Docker image does not have.
    root = File.expand_path('../..', File.dirname(__FILE__))
    gemspec = File.read(File.join(root, 'bgp4r.gemspec'))
    gemfile = File.read(File.join(root, 'Gemfile'))
    assert_match(/^\s*s\.add(_runtime)?_dependency\s+['"]logger['"]/, gemspec)
    assert_match(/^\s*gem\s+['"]logger['"]/, gemfile)
  end
  def test_ipaddr_arithmetic
    ip1 = IPAddr.new('10.0.0.1/28')
    ip2 = IPAddr.new('10.0.0.1/24')
    ip3 = IPAddr.new('10.0.0.1/12')
    assert_equal('10.0.0.16/28', ip1 ^ 1)
    assert_equal('10.0.0.32/28', ip1 ^ 2)
    assert_equal('10.0.1.0/24',  ip2 ^ 1)
    assert_equal('10.0.2.0/24',  ip2 ^ 2)
    assert_equal('10.16.0.0/12', ip3 ^ 1)
    assert_equal('10.32.0.0/12', ip3 ^ 2)
  end
  def test_ipaddr_plus_matches_ruby_ipaddr
    # Same result as IPAddr#+ in Ruby's own ipaddr: an IPAddr, mask kept.
    # IPAddr.new masks the address, so 10.0.0.1/24 would start at 10.0.0.0.
    ip = IPAddr.new('10.0.0.0/24') + 5
    assert_kind_of(IPAddr, ip)
    assert_equal('10.0.0.5', ip.to_s)
    assert_equal(24, ip.prefix)
    v6 = IPAddr.new('2014:aa:bb:cc::1') + 15
    assert_kind_of(IPAddr, v6)
    assert_equal('2014:aa:bb:cc::10', v6.to_s)
  end
  def test_ipaddr_v6_arithmetic
    ip1 = IPAddr.new('2014:aa:bb:cc::1/126')
    assert_equal('2014:aa:bb:cc::4/126', ip1 ^ 1)
    assert_equal('2014:aa:bb:cc::8/126', ip1 ^ 2)
    assert_equal('2014:aa:bb:cc::c/126', ip1 ^ 3)
    assert_equal('2014:aa:bb:cc::10/126', ip1 ^ 4)
    assert_equal('2014:aa:bb:cc::14/126', ip1 ^ 5)
  end
  def test_string_pack
    sbin = ['00'].pack('H*')
    assert_equal '0x0000:  00', sbin.hexlify.join
    sbin = ['0001'].pack('H*')
    assert_equal '0x0000:  0001', sbin.hexlify.join
    sbin = ['000102'].pack('H*')
    assert_equal '0x0000:  0001 02', sbin.hexlify.join
    sbin = ['000102030405060708090a0b0c0d0e0f'].pack('H*')
    assert_equal '0x0000:  0001 0203 0405 0607 0809 0a0b 0c0d 0e0f', sbin.hexlify.join
    sbin = ['000102030405060708090a0b0c0d0e0f10'].pack('H*')
    sbin = ['000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20'].pack('H*')
    assert_equal '0x0001:  1011 1213 1415 1617 1819 1a1b 1c1d 1e1f', sbin.hexlify[2]
    assert_equal '0x0002:  20', sbin.hexlify[3]
  end
  def test_hexlify_edges
    # A string that was never packed is not a hex dump candidate: it comes
    # back as it is.
    assert_equal('not packed', 'not packed'.hexlify)
    # Nothing to dump.
    assert_equal([''], [''].pack('H*').hexlify)
    assert_equal('', String.new.hexlify.join)
    # One trailing odd octet after a full 16 octet line.
    sbin = ['000102030405060708090a0b0c0d0e0fff'].pack('H*')
    assert_equal(['', '0x0000:  0001 0203 0405 0607 0809 0a0b 0c0d 0e0f', '0x0001:  ff'],
                 sbin.hexlify)
  end
  def save_log_state
    [Log.class_variable_get(:@@logger), (Log.class_variable_get(:@@time) if Log.class_variable_defined?(:@@time))]
  end
  def restore_log_state(state)
    Log.class_variable_set(:@@logger, state[0])
    Log.class_variable_set(:@@time, state[1]) if state[1]
  end
  def test_log_clear_with_shell_characters_in_filename
    state = save_log_state
    Dir.mktmpdir do |dir|
      other = File.join(dir, 'other')
      File.write(other, 'keep')
      name = File.join(dir, 'bgp log;touch pwned')
      Log.set_filename(name)
      Log.info 'before clear'
      assert_match(/before clear/, File.read(name))
      Dir.chdir(dir) { Log.clear }
      assert(File.exist?(name))
      assert_no_match(/before clear/, File.read(name))
      assert_equal(name, Log.filename)
      assert_equal('keep', File.read(other))
      assert_equal(['bgp log;touch pwned', 'other'], Dir.children(dir).sort)
      Log.class_variable_get(:@@logger).close
    end
  ensure
    restore_log_state(state)
  end
  def test_log_clear_when_logging_to_stream
    state = save_log_state
    Log.class_variable_set(:@@logger, nil)
    logger = Log.create(StringIO.new)
    Log.clear
    assert_same(logger, Log.class_variable_get(:@@logger))
  ensure
    restore_log_state(state)
  end
  def test_log_time_reset
    state = save_log_state
    Log.class_variable_set(:@@time, Time.now - 3600)
    Log.time_reset
    assert_operator(Time.now - Log.class_variable_get(:@@time), :<, 5)
  ensure
    restore_log_state(state)
  end
  def test_log_start_creates_one_logger
    state = save_log_state
    Log.class_variable_set(:@@logger, nil)
    logger = Log.start(StringIO.new)
    assert_kind_of(Log, logger)
    assert_same(logger, Log.class_variable_get(:@@logger))
    # Log.create is memoized: a second start keeps the first logger.
    assert_same(logger, Log.start(StringIO.new))
  ensure
    restore_log_state(state)
  end
  def test_log_level
    state = save_log_state
    Log.class_variable_set(:@@logger, nil)
    Log.start(StringIO.new)
    { Logger::DEBUG => "(0) 'DEBUG'",
      Logger::INFO  => "(1) 'INFO'",
      Logger::WARN  => "(2) 'WARN'",
      Logger::ERROR => "(3) 'ERROR'",
      Logger::FATAL => "(4) 'FATAL'" }.each { |level, name|
      Log.level = level
      assert_equal(name, Log.level)
      assert_equal(level, Log.class_variable_get(:@@logger).level)
    }
    # Out of range is ignored rather than raised, and nothing moves.
    Log.level = 5
    assert_equal("(4) 'FATAL'", Log.level)
    Log.level = -1
    assert_equal("(4) 'FATAL'", Log.level)
  ensure
    restore_log_state(state)
  end
  def test_log_writes_every_severity
    state = save_log_state
    io = StringIO.new
    Log.class_variable_set(:@@logger, nil)
    Log.start(io)
    Log.level = Logger::DEBUG
    Log.debug 'a debug line'
    Log.info 'an info line'
    Log.warn 'a warn line'
    Log.error 'an error line'
    Log.fatal 'a fatal line'
    out = io.string
    assert_match(/DEBUG -- : a debug line$/, out)
    assert_match(/INFO -- : an info line$/, out)
    assert_match(/WARN -- : a warn line$/, out)
    assert_match(/ERROR -- : an error line$/, out)
    assert_match(/FATAL -- : a fatal line$/, out)
  ensure
    restore_log_state(state)
  end
  def test_log_direction_markers
    state = save_log_state
    io = StringIO.new
    Log.class_variable_set(:@@logger, nil)
    Log.start(io)
    Log.time_reset
    Log << 'sent an open'
    Log >> 'got a keepalive'
    lines = io.string.lines.collect { |l| l.chomp }
    assert_match(/\A<< \d+\.\d{6}: sent an open\z/, lines[0])
    assert_match(/\A>> \d+\.\d{6}: got a keepalive\z/, lines[1])
  ensure
    restore_log_state(state)
  end
  def test_log_is_quiet_with_no_logger
    state = save_log_state
    Log.class_variable_set(:@@logger, nil)
    Log.time_reset
    assert_nothing_raised do
      Log.debug 'x'
      Log.info 'x'
      Log.warn 'x'
      Log.error 'x'
      Log.fatal 'x'
      Log << 'x'
      Log >> 'x'
    end
  ensure
    restore_log_state(state)
  end
end
